{ %OPT=-OoNOASMINLINE -Si }
{ %RESULT=0 }
{ Smoke: -OoNOASMINLINE makes is_assembler_inlineable refuse the
  candidate, so the proc is left as a normal CALL. The body itself
  is still valid -- this just verifies the option parses and the
  gate honours it without the rest of the inline pipeline tripping. }
{$mode objfpc}
{$asmmode intel}
program tinlfpc_asm_inline_off;

function id(x: longint): longint; assembler; nostackframe; inline;
asm
  mov eax, x
end;

begin
  if id(7) <> 7 then halt(1);
  if id(-3) <> -3 then halt(2);
end.
