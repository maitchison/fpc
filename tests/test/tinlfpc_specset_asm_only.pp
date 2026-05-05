{ %OPT=-Si }
{ %RESULT=0 }
program tinlfpc_specset_asm_only;

{$mode objfpc}
{$asmmode intel}

var
  g_result: longint;

procedure foo(x: boolean specialize [true, false]);
begin
  g_result := 100;
  asm
    mov eax, g_result
    add eax, 1
    mov g_result, eax
  end;
  writeln(g_result);
end;

begin
  foo(true);
  foo(false);
end.
