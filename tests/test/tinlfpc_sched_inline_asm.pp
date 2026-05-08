{ %OPT=-OoSCHEDULE -OoNOAUTOSCHEDASM -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Inline-asm boundary (legacy semantics, -OoNOAUTOSCHEDASM opt-out):
  scheduler must NOT reorder instructions inside a user `asm ... end;`
  block embedded in a normal Pascal procedure when the auto rule is
  off and the block doesn't carry `{$schedule on}`. The
  TAsmScheduler.Optimize loop in compiler/aopt.pas skips
  mark_AsmBlockStart..mark_AsmBlockEnd ranges with the scheduler flag
  cleared; this test exercises that skip with a sequence whose ordering
  is semantically required.

  The auto-on rule (default) is exercised by tinlfpc_sched_auto_asm.

  The asm block computes (a+b)*2 - b = 2a + b via:
    mov eax, a
    add eax, b
    shl eax, 1
    sub eax, b
  Any swap of the inner three is wrong.
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
