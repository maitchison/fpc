{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Verifies the `schedule` proc modifier opts a pure assembler proc
  in to the i386 PMMX scheduler. Without the modifier, psub.pas
  unconditionally bypasses the scheduler for `pi_is_assembler`
  procs; with it, the scheduler runs over the body. Semantics must
  be unchanged.

  ABI: under FPC's go32v2/Win32 register convention, the first int
  param sits in EAX and the second in EDX, so we accumulate into
  EAX (the return reg) using EDX as the second source.
}
program tinlfpc_sched_modifier;

{$asmmode intel}

{ Pure asm proc with the new `schedule` modifier. The body has
  several independent UV-pairable instructions the scheduler may
  reorder; the result must still be 2a + b. }
function mix(a, b: longint): longint; assembler; nostackframe; schedule;
asm
  add eax, edx           { eax := a + b }
  shl eax, 1             { eax := 2(a+b) }
  sub eax, edx           { eax := 2a + b }
end;

{ Same logic, no modifier -- scheduler stays out per the existing
  pi_is_assembler bypass. Result must match. }
function mix_noopt(a, b: longint): longint; assembler; nostackframe;
asm
  add eax, edx
  shl eax, 1
  sub eax, edx
end;

begin
  if mix(10, 3)   <> 23  then halt(1);
  if mix(0, 5)    <> 5   then halt(2);
  if mix(7, -2)   <> 12  then halt(3);
  if mix(50, 100) <> 200 then halt(4);

  { Cross-check against the no-opt version. }
  if mix_noopt(10, 3)   <> 23  then halt(11);
  if mix_noopt(50, 100) <> 200 then halt(14);
end.
