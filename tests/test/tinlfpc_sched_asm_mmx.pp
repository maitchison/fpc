{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS_MIN=1 }
{
  PMMX scheduler against an MMX inline-asm body, opted in via
  {$schedule on}. Two RAW chains (mm1 and mm2) side-by-side on
  disjoint registers -- the canonical cascade shape that Path A.5
  (relaxed top-level gate + multi-pass to fixpoint) interleaves
  into U/V pairs.

  Pre-cascade-fix: the over-eager top-level gate refused to
  attempt hoists at the chain boundary because the last paddw
  mm1 already paired with the first movd mm2. That single pair
  was preserved, but the remaining cross-chain pair opportunities
  were not even considered -- SCHED_SWAPS came out 0.

  Post-cascade-fix: TryHoistBackward is called at every pairable
  cur and AlreadyPairsWithNext rejects only true no-op churn.
  The forward walk iterates to fixpoint, so chain B instructions
  cascade upstream into chain A across multiple passes. Net
  effect: ~3 cycles saved on PMMX hardware.

  We assert SCHED_SWAPS_MIN=1 (instead of an exact count) so
  future heuristic refinements that reach the same end-state with
  fewer intermediate moves don't regress this test.

  Correctness side: each PADDW doubles the low 16-bit lane.
    mm1 starts as 4 -> 4*2*2*2 = 32 in the low word.
    mm2 starts as 7 -> 7*2*2*2 = 56 in the low word.
}
program tinlfpc_sched_asm_mmx;

{$mode objfpc}
{$asmmode att}

var
  result_mm1, result_mm2: longint;

begin
  {$schedule on}
  asm
    movl  $4, %eax
    movd  %eax, %mm1
    paddw %mm1, %mm1
    paddw %mm1, %mm1
    paddw %mm1, %mm1
    movl  $7, %ebx
    movd  %ebx, %mm2
    paddw %mm2, %mm2
    paddw %mm2, %mm2
    paddw %mm2, %mm2
    movd  %mm1, %eax
    movl  %eax, result_mm1
    movd  %mm2, %eax
    movl  %eax, result_mm2
    emms
  end;
  if result_mm1 <> 32 then halt(1);
  if result_mm2 <> 56 then halt(2);
end.
