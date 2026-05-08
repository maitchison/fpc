{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -CpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS_MIN=3 }
{
  Cascade interleaving of two independent register chains.

  Two MMX RAW chains side-by-side share zero registers: hoisting an
  instruction from chain B into chain A creates new U/V pairs without
  losing any. The PRE-cascade-fix scheduler refused these hoists at
  the top-level gate because chain B's first instruction already paired
  with chain A's last (prv-pairs-cur shortcut). Path A.5 drops that gate
  and runs forward-walks to fixpoint, letting hoists cascade upstream.

  Linear order:
    movd  mm1, eax   ; chain A: mm1 RAW-dep (paddw reads what previous
    paddw mm1, mm1   ;                       paddw just wrote)
    paddw mm1, mm1
    paddw mm1, mm1
    movd  mm2, ebx   ; chain B: independent of chain A, mm2 RAW-dep
    paddw mm2, mm2
    paddw mm2, mm2
    paddw mm2, mm2

  Optimal interleaved form (4 U/V pairs vs original 1):
    movd  mm1, eax   |  movd  mm2, ebx
    paddw mm1, mm1   |  paddw mm2, mm2
    paddw mm1, mm1   |  paddw mm2, mm2
    paddw mm1, mm1   |  paddw mm2, mm2

  ~3 cycles saved on Pentium MMX hardware. Six hoists fire to reach
  the optimum (one per chain-B instruction, across multiple passes);
  we assert >=3 to leave room for future heuristic refinements that
  reach the same end-state with fewer intermediate moves.

  The MMX values are seeded as constants, doubled three times each via
  paddw, then read back -- so on PMMX-class hardware the result is
  deterministic regardless of pair-cycle reordering: 4 -> 32, 7 -> 56.
}
program tinlfpc_sched_cascade_chains;

{$asmmode intel}

var
  result_mm1, result_mm2: longint;

begin
  asm
    mov  eax, 4
    mov  ebx, 7
    movd  mm1, eax
    paddw mm1, mm1
    paddw mm1, mm1
    paddw mm1, mm1
    movd  mm2, ebx
    paddw mm2, mm2
    paddw mm2, mm2
    paddw mm2, mm2
    movd  eax, mm1
    mov   result_mm1, eax
    movd  eax, mm2
    mov   result_mm2, eax
    emms
  end;
  if result_mm1 <> 32 then halt(1);
  if result_mm2 <> 56 then halt(2);
end.
