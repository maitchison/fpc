{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS=0 }
{
  Inline-asm boundary, post-unified-switch:
  the scheduler is enabled (-OoSCHEDULE) and runs over the asm block
  inside this Pascal proc, but the body has no reorderable
  instructions (every adjacent pair shares EAX or writes flags), so
  no swap fires and the body emits in source order.

  The asm block computes (a+b)*2 - b = 2a + b via:
    mov eax, a
    add eax, b
    shl eax, 1
    sub eax, b
  Any swap of the inner three is wrong; HasDep correctly forbids
  every reorder.
}
program tinlfpc_sched_inline_asm;

{$asmmode intel}

function mix(a, b: longint): longint;
var
  tmp: longint;
begin
  asm
    mov eax, a
    add eax, b
    shl eax, 1
    sub eax, b
    mov tmp, eax
  end;
  mix := tmp;
end;

begin
  if mix(10, 3) <> 23 then halt(1);     { (10+3)*2 - 3 = 23 }
  if mix(0, 5)  <> 5  then halt(2);     { (0+5)*2  - 5 = 5  }
  if mix(7, -2) <> 12 then halt(3);     { (7+(-2))*2 - (-2) = 12 }
end.
