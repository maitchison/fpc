{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS=0 }
{
  v1 PMMX scheduler against an MMX inline-asm body, opted in via
  {$schedule on}. v1's pairable set
  (compiler/i386/schedi386.pas:OpcodeIsPairable) is integer-only --
  MOVD, PADDW, etc. fall into the "non-pairable but not a barrier"
  bucket -- so the scheduler walks the body but never finds a
  [P, NP, P] shape and never swaps. Marker count must be 0.

  When Path A extends the pairable set to MMX integer ALU
  (PADDx, PSUBx, PCMPx, PAND/POR/PXOR/PANDN, MOVD, MOVQ, PACK*,
  PUNPCK*) this test will start failing with markers > 0. That's
  the explicit signal that:
    (a) the pair-formation logic now reaches MMX, and
    (b) the test should be re-evaluated -- bump %SCHED_SWAPS to the
        new expected count after auditing the .s, and confirm the
        two independent mm1/mm2 chains are still serialised
        correctly (each chain's PADDW is RAW-dependent on the
        previous PADDW -- the scheduler must NOT pair within a
        chain, only across the two chains).

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
