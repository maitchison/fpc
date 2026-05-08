{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Verifies the `schedule` proc modifier still works as a force-on
  override for pure-asm procs under the unified $schedule switch.
  Under the new model -OoSCHEDULE alone schedules pure-asm procs
  too, so the modifier is functionally a no-op when the global
  switch is on -- but it remains meaningful when callers compile
  with -OoSCHEDULE off (or {$schedule off} active around the proc):
  the modifier still flips scheduling on for that one proc.

  This test exercises the global-on case end-to-end. Both bodies
  must produce the same numeric result regardless of scheduling
  decisions; the body has no reorderable instructions (eax+flag
  cascade) so no swap fires either way.

  ABI: under FPC's go32v2/Win32 register convention, the first int
  param sits in EAX and the second in EDX, so we accumulate into
  EAX (the return reg) using EDX as the second source.
}
program tinlfpc_sched_modifier;

{$asmmode intel}

{ Pure asm proc with the `schedule` modifier. }
function mix(a, b: longint): longint; assembler; nostackframe; schedule;
asm
  add eax, edx           { eax := a + b }
  shl eax, 1             { eax := 2(a+b) }
  sub eax, edx           { eax := 2a + b }
end;

{ Same logic, no modifier -- under the unified switch with -OoSCHEDULE
  on, the scheduler also runs over this body. Result must match. }
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
