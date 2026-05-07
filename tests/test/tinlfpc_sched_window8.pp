{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS_MIN=1 }
{
  Path A / A3: backward sliding window (-8).

  v1 looked only at the [P, NP, P] one-step shape -- a candidate
  buried more than one position behind a P had no chance of being
  hoisted. Path A's TryHoistBackward walks up to 8 eligible
  positions backward looking for an anchor.

  Body shape:

    movd  mm0, eax           ; UV    setup chain 1
    paddw mm0, mm0           ; UV    chain 1; depends on mm0
    bswap ecx                ; NP    intermediate (no flags, no MMX)
    bswap ecx                ; NP
    bswap ecx                ; NP
    bswap ecx                ; NP
    bswap ecx                ; NP
    movd  mm5, edx           ; UV    INDEPENDENT of mm0 chain --
                                     buried 5 hops behind paddw mm0.
                                     Should hoist back to pair with
                                     paddw mm0 (UV+UV across the
                                     NP intermediates).
    paddw mm5, mm5           ; UV    chain 2; depends on mm5
    paddw mm0, mm5           ; UV    combine
    movd  eax, mm0           ; UV    return
    emms

  v1 had no way to form the paddw-mm0 / movd-mm5 pair across the
  bswap chain; the P, NP, P window was too narrow. Path A's
  window-of-8 should fire exactly one hoist here.

  bswap is non-pairable (NP) but commutes with our MMX target on
  registers (ecx vs mm5/edx) and on flags (bswap writes none) and
  on memory (no operand). So the per-step adjacent-swap safety
  test in TryHoistBackward clears at every intermediate, and the
  walker reaches the paddw-mm0 anchor.
}
program tinlfpc_sched_window8;

{$asmmode intel}

function deep_chain(a, b: longint): longint; assembler; nostackframe; schedule;
asm
  movd  mm0, eax            { mm0 = a                                }
  paddw mm0, mm0            { mm0 = 2a                               }
  bswap ecx                 { NP gap, no MMX, no flags, no mem      }
  bswap ecx
  bswap ecx
  bswap ecx
  bswap ecx
  movd  mm5, edx            { mm5 = b -- hoist target               }
  paddw mm5, mm5            { mm5 = 2b                               }
  paddw mm0, mm5            { mm0 = 2a + 2b                          }
  movd  eax, mm0            { return                                 }
  emms
end;

begin
  if deep_chain(3, 5)  <> (2*3 + 2*5)  then halt(1);   { 16 }
  if deep_chain(0, 7)  <> (0   + 14)   then halt(2);   { 14 }
  if deep_chain(1, 0)  <> (2   + 0)    then halt(3);   { 2  }
  if deep_chain(10, 1) <> (20  + 2)    then halt(4);   { 22 }
end.
