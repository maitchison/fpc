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

    A simplified, conservative model is used here. We split opcodes
    into two classes:

      UV-pairable -- single-cycle ALU/move/lea/inc/dec/nop forms that
                     can run in either pipe.

      Non-pairable (NP) -- everything else: multi-cycle, microcoded,
                     control flow, memory string ops, FP, MMX, etc.
                     Conservatively treated as "issues alone".

    Pair-validity (whether a UV+UV pair is actually legal as second-
    instruction-in-V) requires:

      * No register read-after-write between the pair (no RAW).
      * No flag read-after-write.
      * No write-after-write to the same register/flags.
      * At most one of the two references memory (we do not have alias
        analysis, so we forbid both-mem).

    --- algorithm --------------------------------------------------------

    Walk the basic block. When we see:

        I1  (UV-pairable)
        I2  (non-pairable, or pairable but blocking against I1)
        I3  (UV-pairable)

    and (a) I2 and I3 are independent (we can swap them), and (b) I1
    and I3 form a legal pair, then rewrite to:

        I1  I3  I2

    so I1 and I3 issue together as U+V on the next cycle, and I2
    issues alone afterwards. Net saving on PMMX: one cycle.

    This is a peephole-style rewrite (one local move at a time) rather
    than a full list-scheduler. Easier to validate; once a pair forms
    we re-scan and may pair the displaced I2 with whatever lands next.

    Future work: 2-distance moves, AGI-stall avoidance, U-only/V-only
    modelling (currently we treat the pairable set as fully symmetric).

    --- safety -----------------------------------------------------------

    Block barriers (never reorder across):
      ait_label, ait_marker, ait_align, ait_section, ait_directive,
      ait_cfi, ait_stab/ait_dwarf-equivalent debug nodes, anything
      not explicitly known.
      Any control-flow instruction (jmp/jcc/call/ret/int/loop/...).

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
        function SchedulerPass1Cpu(var p: tai): boolean; override;
      end;

  Implementation

    uses
      globtype, globals,
      verbose,
      cpuinfo,
      aasmcpu;


    { ------------------------------------------------------------------
      Static classification.

      tasmop on x86 has nearly 2000 enumerators -- far beyond Pascal's
      256-element set ceiling -- so each predicate is expressed as a
      case statement rather than `op in some_set`.
      ------------------------------------------------------------------ }

    function OpcodeIsPairable(op: tasmop): boolean;
      begin
        case op of
          A_MOV,
          A_ADD, A_SUB, A_AND, A_OR, A_XOR, A_CMP, A_TEST,
          A_INC, A_DEC,
          A_LEA,
          A_NOP:
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
          A_CMPSB, A_CMPSW, A_CMPSD:
            Result := true;
          else
            Result := false;
        end;
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


    { ------------------------------------------------------------------
      Main pass. Walks the block applying I1/I2/I3 swap.
      ------------------------------------------------------------------ }
    function TCpuPreRegallocScheduler.SchedulerPass1Cpu(var p: tai): boolean;
      var
        i1, i2, i3: tai;
      begin
        Result := true;

        { Bail if not on a P5/PMMX target. }
        if not (current_settings.optimizecputype in [cpu_Pentium, cpu_PentiumMMX]) then
          begin
            p := BlockEnd;
            exit;
          end;

        i1 := BlockStart;
        while assigned(i1) and (i1 <> BlockEnd) do
          begin
            if (i1.typ <> ait_instruction) or IsBarrier(i1) then
              begin
                i1 := tai(i1.next);
                continue;
              end;

            i2 := NextEligible(i1);
            if (i2 = nil) or (i2 = BlockEnd) or IsBarrier(i2) then
              begin
                i1 := tai(i1.next);
                continue;
              end;

            if not IsPairable(i1) then
              begin
                i1 := tai(i1.next);
                continue;
              end;

            { i1 + i2 already pair? leave alone. }
            if CanPair(Self, i1, i2) then
              begin
                i1 := tai(i1.next);
                continue;
              end;

            { try i3 as the candidate to promote into V slot. }
            i3 := NextEligible(i2);
            if (i3 = nil) or (i3 = BlockEnd) or IsBarrier(i3) then
              begin
                i1 := tai(i1.next);
                continue;
              end;

            if not CanPair(Self, i1, i3) then
              begin
                i1 := tai(i1.next);
                continue;
              end;

            if HasDep(Self, i2, i3) then
              begin
                i1 := tai(i1.next);
                continue;
              end;

            { Move i3 to sit immediately after i1 (before i2). }
            AsmL.Remove(i3);
            AsmL.InsertAfter(i3, i1);
            { Re-anchor at the moved i3 -- it might pair with the
              instruction now after it. }
            i1 := tai(i3.next);
          end;

        { Tell the outer walker we own the iteration. }
        p := BlockEnd;
      end;

end.
