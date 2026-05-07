{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS_MIN=1 }
{
  Path A / A2: U/V/UV classification.

  Two pure-asm procs exercise OpcodeClass / CanIssueParallel:

    pair_uv_uonly  PMULLW (U-only) followed by an NP gap, then
                   PADDW (UV) on independent registers. The UV
                   target should hoist back to pair with the
                   U-only anchor (UV + UOnly is legal per A2).
                   Expect at least one sched-swap marker.

    no_pair_uonly  Two U-only PMULLWs adjacent, with PXOR
                   initialisation in between (initial mm regs
                   are caller state). Even with the registers
                   independent, A2 must reject U+U pairing.
                   This proc is a sentinel: a future regression
                   that lets U-only ops issue together would
                   bump the swap count above the bound below.

  Returns are simple integer reductions; values verified to halt
  on a wrong answer.
}
program tinlfpc_sched_pmmx_pairtable;

{$asmmode intel}

{ pair_uv_uonly: anchor = pmullw mm0, mm0 (U-only).
  Independent PADDW mm5, mm5 (UV) sits behind an NP bswap chain.
  Path A should hoist the PADDW back to pair with the PMULLW. }
function pair_uv_uonly(a, b: longint): longint; assembler; nostackframe; schedule;
asm
  movd   mm0, eax           { mm0 = a                                }
  pxor   mm5, mm5           { mm5 = 0   (UV; ensures mm5 is defined) }
  movd   mm6, edx           { mm6 = b   (UV)                         }
  paddw  mm5, mm6           { mm5 = b   (UV)                         }
  pmullw mm0, mm0           { mm0 = a*a (U-only) -- anchor           }
  bswap  ecx                { NP                                     }
  bswap  ecx                { NP                                     }
  paddw  mm5, mm5           { mm5 = 2b  (UV) -- hoist target         }
  paddw  mm0, mm5           { mm0 = a*a + 2b                         }
  movd   eax, mm0           { return                                 }
  emms
end;

{ no_pair_uonly: two U-only PMULLWs back-to-back. Even though they
  use different register banks (mm2 vs mm3), CanIssueParallel must
  refuse to pair them. The PXORs preceding pair UV+UV cleanly --
  no opportunity for hoist that crosses a PMULLW. }
function no_pair_uonly(a: longint): longint; assembler; nostackframe; schedule;
asm
  pxor   mm2, mm2           { mm2 = 0  (UV)                          }
  pxor   mm3, mm3           { mm3 = 0  (UV)                          }
  movd   mm2, eax           { mm2 = a  (UV)                          }
  movd   mm3, eax           { mm3 = a  (UV)                          }
  pmullw mm2, mm2           { mm2 = a*a (U-only)                     }
  pmullw mm3, mm3           { mm3 = a*a (U-only) -- next to pmullw mm2 }
  paddw  mm2, mm3           { mm2 = 2*a*a (UV)                       }
  movd   eax, mm2           { return                                 }
  emms
end;

begin
  if pair_uv_uonly(3, 4)  <> (3*3 + 2*4)  then halt(1);   { 17 }
  if pair_uv_uonly(0, 5)  <> (0   + 10)   then halt(2);   { 10 }
  if pair_uv_uonly(2, 1)  <> (2*2 + 2)    then halt(3);   {  6 }
  if no_pair_uonly(3)     <> 2*3*3        then halt(4);   { 18 }
  if no_pair_uonly(7)     <> 2*7*7        then halt(5);   { 98 }
end.
