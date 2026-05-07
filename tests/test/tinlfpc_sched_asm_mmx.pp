{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS=0 }
{
  PMMX scheduler against an MMX inline-asm body, opted in via
  {$schedule on}. Marker count must be 0 -- but the reason is more
  subtle now than it was before Path A.

  Pre-Path-A: MOVD/PADDW were not in OpcodeIsPairable, so the
  scheduler walked the body but never found any pair-able
  candidates and never swapped.

  Post-Path-A (A1 lands MMX as pairable, A3 walks a backward
  window of 8): every cross-chain adjacency in this body already
  forms a valid U/V pair by linear order alone. mm1's chain ends
  at `paddw mm1, mm1` (instr [4]); the next instruction `movl $7,
  %ebx` has no register/flag/memory overlap with it, so [4]+[5]
  already pair. The mm2 chain's first paddw is RAW-dep'd on the
  preceding `movd %ebx, %mm2`, so it can't slide left past it.
  Net: nothing for the backward-window to hoist.

  This test therefore stays at 0 markers as a regression sentinel.
  If a future scheduler revision (Path B / list-scheduler) ever
  starts forming new pairs here, the marker count will rise --
  audit the .s and update the assertion.

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
