{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Verifies {$schedule on} opts an inline asm block in to the i386 PMMX
  scheduler. The scheduler is allowed to reorder UV-pairable
  instructions inside the block as long as the dep model agrees;
  semantics must be unchanged. Independent moves (mov-imm to
  different registers) inside an asm block are reorderable; the
  test arithmetic comes out the same regardless of order.

  Companion negative test: tinlfpc_sched_inline_asm.pp (no opt-in --
  scheduler must NOT touch the block).
}
program tinlfpc_sched_directive;

{$asmmode intel}

function mix(a, b: longint): longint;
var
  tmp: longint;
begin
  {$schedule on}
  asm
    mov eax, a
    add eax, b           { eax := a + b }
    shl eax, 1           { eax := 2(a+b) }
    sub eax, b           { eax := 2a + b }
    mov tmp, eax
  end;
  {$schedule off}
  mix := tmp;
end;

begin
  if mix(10, 3) <> 23 then halt(1);     { 2*10 + 3 }
  if mix(0, 5)  <> 5  then halt(2);     { 0  + 5 }
  if mix(7, -2) <> 12 then halt(3);     { 14 + (-2) }
  if mix(50, 100) <> 200 then halt(4);  { 100 + 100 }
end.
