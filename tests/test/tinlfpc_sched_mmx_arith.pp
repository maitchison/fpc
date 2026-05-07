{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS_MIN=1 }
{
  Path A / A1: pairable-set extension (MMX integer).

  Without A1, MOVD and PADDW were not in OpcodeIsPairable, so the
  scheduler treated every MMX instruction as non-pairable and could
  never form a pair across an MMX boundary. A1 adds the MMX
  integer ALU / move set; this test exercises that addition by
  burying an independent PADDW behind an NP intermediate so v1
  couldn't have paired it, and Path A should.

  Body: chain 1 on mm0 first, NP gap, chain 2 on mm5. The two
  chains share no registers; PADDW on mm5 should hoist back to
  pair with PADDW on mm0 (both UV).
}
program tinlfpc_sched_mmx_arith;

{$asmmode intel}

function two_chains(a, b: longint): longint; assembler; nostackframe; schedule;
asm
  movd  mm0, eax            { mm0 = a                                }
  paddw mm0, mm0            { mm0 = 2a                               }
  bswap ecx                 { NP gap                                 }
  bswap ecx
  bswap ecx
  movd  mm5, edx            { mm5 = b -- independent chain           }
  paddw mm5, mm5            { mm5 = 2b -- candidate for hoist        }
  paddw mm0, mm5            { mm0 = 2a + 2b                          }
  movd  eax, mm0            { return                                 }
  emms
end;

begin
  if two_chains(2, 3) <> (2*2 + 2*3) then halt(1);   { 10 }
  if two_chains(0, 5) <> (0   + 10)  then halt(2);   { 10 }
  if two_chains(7, 0) <> (14  + 0)   then halt(3);   { 14 }
  if two_chains(1, 1) <> 4           then halt(4);
end.
