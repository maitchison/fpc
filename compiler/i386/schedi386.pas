{
    Copyright (c) 2026 by the Free Pascal development team

    Pentium / PentiumMMX U/V pair-aware reorderer for i386.

    Runs at the post-peephole / post-RA hook in psub.pas. Operates on
    real registers, after the existing peephole optimiser has settled.

    --- background -------------------------------------------------------

    The classic Pentium (P5) and Pentium MMX (P55C) cores are in-order
    superscalar with two integer pipes named U and V. In one cycle the
    core can issue ONE instruction in U and at most ONE additional
    instruction in V, but only if a strict set of pairing rules is
    satisfied. References:

      Intel Pentium Family Developer's Manual, Vol. 3, ch. "Optimization
        Techniques for the Pentium Processor".
      Agner Fog, "Optimizing assembly language for x86", appendix on
        Pentium scheduling.

    Opcode classes (Path A / A2):

      pc_UV     -- pairable, runs in either pipe. Integer ALU/move/lea/
                   inc/dec/nop and the bulk of MMX integer ALU/cmp/log/
                   pack/unpack/movd/movq.
      pc_UOnly  -- pairable but pinned to U pipe: MMX multiplier
                   (PMUL*, PMADDWD) and MMX shift (PSL*, PSR*).
      pc_VOnly  -- pairable but pinned to V pipe: Jcc / JMP near /
                   CALL near / LOOP / JCXZ / JECXZ. All of these are
                   block barriers in our scheduler so this class is
                   only here for completeness.
      pc_None   -- non-pairable. Multi-cycle / microcoded / FP / etc.
                   "Issues alone" cycle-wise; never enters U+V pairing.

    Pair-validity (whether two instructions can issue together as U+V)
    requires:

      * Both pairable.
      * Not both pc_UOnly and not both pc_VOnly.
      * No register read-after-write between the pair (no RAW).
      * No flag read-after-write.
      * No write-after-write to the same register/flags.
      * At most one of the two references memory (we do not have alias
        analysis, so we forbid both-mem).

    --- algorithm (Path A: backward sliding window) ----------------------

    Walk the basic block forward. At each pairable instruction `target`,
    look backward up to 8 eligible positions for an `anchor` such that:

      * anchor is pairable
      * CanIssueParallel(class(anchor), class(target)) holds
      * target can commute pairwise with every instruction strictly
        between anchor and target (HasDep clears at every step)
      * anchor doesn't already form a pair with its current next
        neighbour (avoid no-op churn that just shuffles which
        adjacency forms the U/V cycle)
      * anchor + target itself form a legal pair (HasDep clears)

    If yes, splice target out and reinsert it immediately after anchor.
    The intermediates shift right by one; semantics are preserved by
    the pairwise commutativity check.

    v1 looked only at the [P, NP, P] one-step shape -- a candidate
    buried more than one position behind a P had no chance. Path A's
    window-of-8 catches NP-laden chains plus register-dep chains
    (e.g. mm0 RAW chain followed by an independent mm5 op).

    Future work (Path B): real list scheduler with a dependency DAG,
    latency-aware priority (PMUL is 3-cycle, AGI is 1-cycle), forward
    motion. See scheduler-plan.md.

    --- safety -----------------------------------------------------------

    Block barriers (never reorder across):
      ait_label, ait_marker, ait_align, ait_section, ait_directive,
      ait_cfi, ait_stab/ait_dwarf-equivalent debug nodes, anything
      not explicitly known.
      Any control-flow instruction (jmp/jcc/call/ret/int/loop/...).
      EMMS / FEMMS  (MMX <-> x87 state transition).
      PUSH / POP / PUSHA / POPA / ENTER / LEAVE  (touch ESP and memory).

    Memory model: any instruction with a memory operand creates a hard
    barrier with any other memory-touching instruction (no alias info).

    Inline asm blocks: skipped via the existing TAsmScheduler.Optimize
    machinery in compiler/aopt.pas (which jumps over mark_AsmBlockStart
    .. mark_AsmBlockEnd ranges).

    Gating: optimizecputype must be cpu_Pentium or cpu_PentiumMMX, AND
    cs_opt_scheduler in optimizerswitches. Non-PMMX targets early-exit.

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    General Public License for more details.

 ****************************************************************************
}

unit schedi386;

{$i fpcdefs.inc}

  Interface

    uses
      cgbase,
      cpubase, aopt,
      Aasmbase, aasmtai, aasmdata;

    Type
      TCpuPreRegallocScheduler = class(TAsmScheduler)
        constructor Create(_AsmL: TAsmList); override;
        destructor Destroy; override;
        function SchedulerPass1Cpu(var p: tai): boolean; override;
      end;

  Implementation

    uses
      globtype, globals,
      cutils,
      verbose,
      cpuinfo,
      aasmcpu,
      fmodule, procinfo;


    { Visibility counters. Each successful [P,NP,P]->[P,P,NP] swap is one
      newly-formed U/V pair on PMMX, saving exactly one cycle in straight-
      line execution. We track three nested totals and emit them at -vd
      level (per-proc, per-unit) plus a per-compile grand total at the
      always-on V_Normal level (so it surfaces without -vh) when any
      swap fired during the run. }
    var
      swaps_proc  : longint;
      swaps_unit  : longint;
      swaps_total : longint;
      last_unit_name : shortstring;


    { ------------------------------------------------------------------
      Static classification.

      tasmop on x86 has nearly 2000 enumerators -- far beyond Pascal's
      256-element set ceiling -- so each predicate is expressed as a
      case statement rather than `op in some_set`.
      ------------------------------------------------------------------ }

    function OpcodeIsPairable(op: tasmop): boolean;
      begin
        case op of
          { Integer ALU / move / lea / inc / dec / nop -- the original
            v1 set; symmetric U/V on P5 and P55C. }
          A_MOV,
          A_ADD, A_SUB, A_AND, A_OR, A_XOR, A_CMP, A_TEST,
          A_INC, A_DEC,
          A_LEA,
          A_NOP,

          { Path A / A1 -- MMX integer ALU / compare / logical / pack /
            unpack / inter-domain move. UV-pairable on P55C (both pipes
            can execute these). }
          A_MOVD, A_MOVQ,
          A_PADDB, A_PADDW, A_PADDD,
          A_PADDSB, A_PADDSW, A_PADDUSB, A_PADDUSW,
          A_PSUBB, A_PSUBW, A_PSUBD,
          A_PSUBSB, A_PSUBSW, A_PSUBUSB, A_PSUBUSW,
          A_PCMPEQB, A_PCMPEQW, A_PCMPEQD,
          A_PCMPGTB, A_PCMPGTW, A_PCMPGTD,
          A_PAND, A_PANDN, A_POR, A_PXOR,
          A_PUNPCKLBW, A_PUNPCKLWD, A_PUNPCKLDQ,
          A_PUNPCKHBW, A_PUNPCKHWD, A_PUNPCKHDQ,
          A_PACKSSDW, A_PACKSSWB, A_PACKUSWB,

          { Path A / A1 -- MMX multiplier (U-only). Pairable, but only
            in U pipe; OpcodeClass below tags these pc_UOnly. }
          A_PMULLW, A_PMULHW, A_PMADDWD,

          { Path A / A1 -- MMX shift (U-only). Pairable, U pipe only. }
          A_PSLLW, A_PSLLD, A_PSLLQ,
          A_PSRLW, A_PSRLD, A_PSRLQ,
          A_PSRAW, A_PSRAD:
            Result := true;
          else
            Result := false;
        end;
      end;


    function OpcodeIsBarrier(op: tasmop): boolean;
      begin
        case op of
          A_JMP, A_Jcc, A_JCXZ, A_JECXZ,
          A_CALL, A_RET, A_RETN, A_RETF,
          A_INT, A_INT3, A_INTO, A_IRET, A_IRETD, A_IRETW,
          A_HLT,
          A_LOOP, A_LOOPE, A_LOOPNE, A_LOOPNZ, A_LOOPZ,
          A_LJMP, A_LCALL,
          A_LFENCE, A_MFENCE, A_SFENCE, A_PAUSE,
          A_RDTSC, A_RDMSR, A_WRMSR,
          A_MOVSB, A_MOVSW, A_MOVSD,
          A_STOSB, A_STOSW, A_STOSD,
          A_LODSB, A_LODSW, A_LODSD,
          A_SCASB, A_SCASW, A_SCASD,
          A_CMPSB, A_CMPSW, A_CMPSD,

          { Path A / A1 -- MMX <-> x87 state-transition. EMMS empties
            the FP tag word so subsequent x87 ops see an empty stack;
            FEMMS is the AMD "fast EMMS" 3DNow! variant. Reordering
            across either is a correctness hazard, and the next
            instruction stalls multiple cycles anyway. }
          A_EMMS, A_FEMMS,

          { Path A / A1 -- stack/frame ops. Touch ESP and memory in
            ways the coarse memory model in HasDep can't reason about;
            v1 missed these. Conservative barrier: never reorder
            across. }
          A_PUSH, A_POP, A_PUSHA, A_PUSHAD, A_POPA, A_POPAD,
          A_ENTER, A_LEAVE:
            Result := true;
          else
            Result := false;
        end;
      end;


    { ------------------------------------------------------------------
      Path A / A2 -- U/V pipe classification.

      Two opcodes can occupy a U/V slot together iff:
        * both pairable
        * they don't both want U-only
        * they don't both want V-only
        * (existing register/flag/memory hazard checks)

      pc_UOnly  : MMX multiplier (PMUL*, PMADDWD) -- multiplier unit
                  lives off the U pipe.
                  MMX shift (PSL*, PSR*) -- shifter unit, U pipe.
      pc_VOnly  : Jcc / JMP near / CALL near / LOOP / JCXZ / JECXZ.
                  All of these are block barriers in our scheduler so
                  they never reach this function with a pairable
                  classification -- pc_VOnly is here for completeness.
      pc_UV     : Everything else in OpcodeIsPairable.
      pc_None   : Anything outside OpcodeIsPairable.

      Source of truth: Intel Pentium Family Developer's Manual Vol. 3,
      ch. 13 ("Optimization Techniques for the Pentium Processor"),
      cross-checked against Agner Fog's Pentium appendix.
      ------------------------------------------------------------------ }
    type
      TPairClass = (pc_None, pc_UV, pc_UOnly, pc_VOnly);


    function OpcodeClass(op: tasmop): TPairClass;
      begin
        case op of
          A_PMULLW, A_PMULHW, A_PMADDWD,
          A_PSLLW, A_PSLLD, A_PSLLQ,
          A_PSRLW, A_PSRLD, A_PSRLQ,
          A_PSRAW, A_PSRAD:
            Result := pc_UOnly;
          else
            if OpcodeIsPairable(op) then
              Result := pc_UV
            else
              Result := pc_None;
        end;
      end;


    function CanIssueParallel(c1, c2: TPairClass): boolean;
      begin
        if (c1 = pc_None) or (c2 = pc_None) then
          exit(false);
        if (c1 = pc_UOnly) and (c2 = pc_UOnly) then
          exit(false);
        if (c1 = pc_VOnly) and (c2 = pc_VOnly) then
          exit(false);
        Result := true;
      end;


    function OpcodeWritesFlags(op: tasmop): boolean;
      begin
        case op of
          A_ADD, A_SUB, A_AND, A_OR, A_XOR, A_CMP, A_TEST,
          A_NEG, A_SHL, A_SHR, A_SAR, A_SAL, A_ROL, A_ROR,
          A_RCL, A_RCR, A_BT, A_BTC, A_BTR, A_BTS,
          A_BSF, A_BSR, A_DIV, A_IDIV, A_MUL, A_IMUL,
          A_INC, A_DEC:
            Result := true;
          else
            Result := false;
        end;
      end;


    function OpcodeReadsFlags(op: tasmop): boolean;
      begin
        case op of
          A_ADC, A_SBB,
          A_Jcc,
          A_CMOVcc,
          A_SETcc,
          A_PUSHF, A_PUSHFD,
          A_LAHF:
            Result := true;
          else
            Result := false;
        end;
      end;


    function WritesFlags(p: tai): boolean;
      begin
        Result := (p.typ = ait_instruction) and OpcodeWritesFlags(taicpu(p).opcode);
      end;


    function ReadsFlags(p: tai): boolean;
      begin
        Result := (p.typ = ait_instruction) and OpcodeReadsFlags(taicpu(p).opcode);
      end;


    function TouchesMemory(p: tai): boolean;
      var
        i: longint;
      begin
        Result := false;
        if p.typ <> ait_instruction then
          exit;
        { LEA has a memory-shaped operand but does NOT load or store
          memory -- it's just address arithmetic. Excluding it lets
          the scheduler pair two adjacent LEAs (very common shape
          after register-allocation). }
        if taicpu(p).opcode = A_LEA then
          exit;
        for i := 0 to taicpu(p).ops - 1 do
          if taicpu(p).oper[i]^.typ = top_ref then
            exit(true);
      end;


    function IsPairable(p: tai): boolean;
      begin
        Result := (p.typ = ait_instruction) and OpcodeIsPairable(taicpu(p).opcode);
      end;


    { Hard barrier: anything we must never reorder anything across. }
    function IsBarrier(p: tai): boolean;
      begin
        case p.typ of
          ait_label, ait_align, ait_section,
          ait_marker, ait_directive,
          ait_cfi,
          ait_symbol, ait_symbol_end,
          ait_function_name,
          ait_force_line:
            Result := true;
          ait_instruction:
            Result := OpcodeIsBarrier(taicpu(p).opcode);
          ait_comment, ait_regalloc, ait_stab:
            Result := false;
          else
            { Anything we don't explicitly recognize is a barrier. }
            Result := true;
        end;
      end;


    { Pessimistic reorder-safety check between two instructions A and
      B (in their original linear order, A before B). Returns true if
      a register/flag/memory dependency forbids reordering them.

      Implementation note: the precise read-vs-write helpers
      (RegLoadedWithNewValue, InstructionLoadsFromReg) are virtual on
      TAoptBase and only have correct overrides on TX86AsmOptimizer,
      which lives in a sibling class hierarchy from TAsmScheduler.
      To avoid duplicating ~600 lines of x86 register-dataflow code
      here, we use a coarser rule: if any register of A appears
      anywhere in B, treat as a dependency. This blocks some
      legitimate reads/reads pairs (cmp+cmp on the same reg, two LEAs
      with shared base) but is correct, and our other constraints
      (memory, flags) are independent. }
    function HasDep(self_: TAsmScheduler; a, b: tai): boolean;

      function AnyRegOf_a_AppearsIn_b: boolean;
        var
          i: longint;
        begin
          Result := true;
          for i := 0 to taicpu(a).ops - 1 do
            case taicpu(a).oper[i]^.typ of
              top_reg:
                if self_.RegInInstruction(taicpu(a).oper[i]^.reg, b) then
                  exit;
              top_ref:
                begin
                  if (taicpu(a).oper[i]^.ref^.base <> NR_NO) and
                     self_.RegInInstruction(taicpu(a).oper[i]^.ref^.base, b) then
                    exit;
                  if (taicpu(a).oper[i]^.ref^.index <> NR_NO) and
                     self_.RegInInstruction(taicpu(a).oper[i]^.ref^.index, b) then
                    exit;
                end;
              else
                ;
            end;
          Result := false;
        end;

      function AnyRegOf_b_AppearsIn_a: boolean;
        var
          i: longint;
        begin
          Result := true;
          for i := 0 to taicpu(b).ops - 1 do
            case taicpu(b).oper[i]^.typ of
              top_reg:
                if self_.RegInInstruction(taicpu(b).oper[i]^.reg, a) then
                  exit;
              top_ref:
                begin
                  if (taicpu(b).oper[i]^.ref^.base <> NR_NO) and
                     self_.RegInInstruction(taicpu(b).oper[i]^.ref^.base, a) then
                    exit;
                  if (taicpu(b).oper[i]^.ref^.index <> NR_NO) and
                     self_.RegInInstruction(taicpu(b).oper[i]^.ref^.index, a) then
                    exit;
                end;
              else
                ;
            end;
          Result := false;
        end;

      begin
        Result := true;
        if (a.typ <> ait_instruction) or (b.typ <> ait_instruction) then
          exit;

        { memory: forbid reorder if BOTH touch memory. }
        if TouchesMemory(a) and TouchesMemory(b) then
          exit;

        { flags: any flag overlap blocks reorder. }
        if (WritesFlags(a) and (ReadsFlags(b) or WritesFlags(b))) or
           (WritesFlags(b) and (ReadsFlags(a) or WritesFlags(a))) or
           (ReadsFlags(a) and WritesFlags(b)) or
           (ReadsFlags(b) and WritesFlags(a)) then
          exit;

        { conservative register dep: any shared reg blocks reorder. }
        if AnyRegOf_a_AppearsIn_b or AnyRegOf_b_AppearsIn_a then
          exit;

        Result := false;
      end;


    function CanPair(self_: TAsmScheduler; i1, i3: tai): boolean;
      begin
        Result := IsPairable(i1) and IsPairable(i3) and
                  CanIssueParallel(OpcodeClass(taicpu(i1).opcode),
                                   OpcodeClass(taicpu(i3).opcode)) and
                  not HasDep(self_, i1, i3);
      end;


    { Returns the next "interesting" tai (skip soft pseudo-nodes).
      A hard barrier is returned -- callers test IsBarrier explicitly. }
    function NextEligible(p: tai): tai;
      var
        q: tai;
      begin
        Result := nil;
        if p = nil then
          exit;
        q := tai(p.next);
        while assigned(q) do
          begin
            if not (q.typ in [ait_comment, ait_regalloc]) then
              exit(q);
            q := tai(q.next);
          end;
      end;


    { Symmetric counterpart for the Path A backward window walk. }
    function PrevEligible(p: tai): tai;
      var
        q: tai;
      begin
        Result := nil;
        if p = nil then
          exit;
        q := tai(p.previous);
        while assigned(q) do
          begin
            if not (q.typ in [ait_comment, ait_regalloc]) then
              exit(q);
            q := tai(q.previous);
          end;
      end;


    { Path A / A3 helper -- does `anchor` already form a legal pair
      with its immediate next eligible neighbour? Used to suppress
      hoists that would just shuffle which adjacency carries the U/V
      cycle (no cycle-count benefit, but real .s churn). }
    function AlreadyPairsWithNext(self_: TAsmScheduler; anchor: tai): boolean;
      var
        n: tai;
      begin
        Result := false;
        n := NextEligible(anchor);
        if (n = nil) or IsBarrier(n) then
          exit;
        Result := CanPair(self_, anchor, n);
      end;


    constructor TCpuPreRegallocScheduler.Create(_AsmL: TAsmList);
      begin
        inherited Create(_AsmL);
        { swaps_proc is reset for each new procdef. _unit and _total
          carry across calls and are flushed in Destroy / finalization. }
        swaps_proc := 0;
      end;


    destructor TCpuPreRegallocScheduler.Destroy;
      var
        modname, procname : shortstring;
      begin
        if swaps_proc > 0 then
          begin
            modname := '';
            if assigned(current_module) and assigned(current_module.modulename) then
              modname := current_module.modulename^;
            procname := '?';
            if assigned(current_procinfo) and
               assigned(current_procinfo.procdef) then
              procname := current_procinfo.procdef.fullprocname(false);

            { Unit boundary: when the module changes between two procs
              that both produced swaps, flush the prior unit's running
              tally before re-zeroing. The very last unit's tally is
              flushed in the unit's finalization block. }
            if (last_unit_name <> '') and (last_unit_name <> modname) then
              begin
                if (swaps_unit > 0) and CheckVerbosity(V_Debug) then
                  Comment(V_Debug,
                    '[scheduler] unit '+last_unit_name+': '+
                    tostr(swaps_unit)+' swap(s) (~'+
                    tostr(swaps_unit)+' cy)');
                swaps_unit := 0;
              end;
            last_unit_name := modname;

            if CheckVerbosity(V_Debug) then
              Comment(V_Debug,
                '[scheduler] '+modname+'.'+procname+': '+
                tostr(swaps_proc)+' swap(s) (~'+
                tostr(swaps_proc)+' cy)');

            inc(swaps_unit, swaps_proc);
            inc(swaps_total, swaps_proc);
            swaps_proc := 0;
          end;
        inherited Destroy;
      end;


    { ------------------------------------------------------------------
      Path A / A3 -- backward sliding window.

      For pairable instruction `target`, walk left up to max_back
      eligible positions looking for an `anchor` we can hoist target
      next to. At each step, target must commute with the new walker
      (HasDep clear); a barrier or a hard dep stops the search.

      Commit when walker is itself pairable + can-issue-parallel
      with target + isn't already pairing with its immediate next
      neighbour (avoid pair-shuffle no-ops via AlreadyPairsWithNext).

      The plumbing for visibility (sched-swap marker comment +
      swaps_proc counter + -vd detail line) lives at the commit
      site so we only spend cycles on string-formatting when a
      swap actually fires.
      ------------------------------------------------------------------ }
    function TryHoistBackward(self_: TAsmScheduler; target: tai;
                              max_back: longint): boolean;
      var
        walker, new_anchor: tai;
        steps : longint;
      begin
        Result := false;
        if not IsPairable(target) then
          exit;
        walker := target;
        steps := 0;
        while steps < max_back do
          begin
            walker := PrevEligible(walker);
            if (walker = nil) or IsBarrier(walker) then
              exit;
            { Adjacent-swap safety: target moves leftwards past walker.
              Each step we re-check; the first failing step stops the
              walk. }
            if HasDep(self_, walker, target) then
              exit;
            inc(steps);

            if IsPairable(walker) and
               CanIssueParallel(OpcodeClass(taicpu(walker).opcode),
                                OpcodeClass(taicpu(target).opcode)) and
               not AlreadyPairsWithNext(self_, walker) then
              begin
                new_anchor := walker;
                self_.AsmL.Remove(target);
                self_.AsmL.InsertAfter(target, new_anchor);
                self_.AsmL.InsertAfter(
                  tai_comment.Create(strpnew('sched-swap')),
                  new_anchor);
                inc(swaps_proc);
                if CheckVerbosity(V_Debug) then
                  Comment(V_Debug,
                    '[scheduler] hoist: '+
                    std_op2str[taicpu(target).opcode]+
                    ' back '+tostr(steps)+' to pair with '+
                    std_op2str[taicpu(new_anchor).opcode]);
                Result := true;
                exit;
              end;
          end;
      end;


    { ------------------------------------------------------------------
      Main pass. Forward walk over the block; for every pairable
      instruction whose immediate-prev eligible neighbour does NOT
      already pair with it, try to hoist it backward up to 8 steps
      to land next to a viable anchor.
      ------------------------------------------------------------------ }
    function TCpuPreRegallocScheduler.SchedulerPass1Cpu(var p: tai): boolean;
      const
        WINDOW_BACK = 8;
      var
        cur, nxt, prv: tai;
      begin
        Result := true;

        { Bail if not on a P5/PMMX target. }
        if not (current_settings.optimizecputype in [cpu_Pentium, cpu_PentiumMMX]) then
          begin
            p := BlockEnd;
            exit;
          end;

        cur := BlockStart;
        while assigned(cur) and (cur <> BlockEnd) do
          begin
            { Cache next BEFORE we possibly mutate the list. If a hoist
              fires, target moves backward; the list immediately after
              `cur` is unchanged so `nxt` is still the correct
              continuation. }
            nxt := tai(cur.next);

            if (cur.typ = ait_instruction) and
               not IsBarrier(cur) and
               IsPairable(cur) then
              begin
                prv := PrevEligible(cur);
                { If immediate-prev is pairable AND already pairs with
                  cur, no hoist can improve on that. }
                if (prv = nil) or IsBarrier(prv) or
                   not IsPairable(prv) or
                   not CanPair(Self, prv, cur) then
                  TryHoistBackward(Self, cur, WINDOW_BACK);
              end;

            cur := nxt;
          end;

        { Tell the outer walker we own the iteration. }
        p := BlockEnd;
      end;


finalization
  { Last unit's running tally was never flushed by a subsequent
    module-boundary -- flush it now. Then dump the per-compile total. }
  if (swaps_unit > 0) and CheckVerbosity(V_Debug) then
    Comment(V_Debug,
      '[scheduler] unit '+last_unit_name+': '+
      tostr(swaps_unit)+' swap(s) (~'+
      tostr(swaps_unit)+' cy)');
  if swaps_total > 0 then
    { V_Normal so the grand total surfaces at default verbosity --
      V_Hint would require -vh which most invocations don't set. }
    Comment(V_Normal,
      '[scheduler] total: '+tostr(swaps_total)+
      ' swap(s) (~'+tostr(swaps_total)+' cy)');
end.
