{ %OPT=-Si }
{ %RESULT=0 }
program tinlfpc_specset_pctif;

{$mode objfpc}
{$asmmode intel}

var
  g_result: longint;

procedure foo(x: boolean specialize [true, false]);
begin
  g_result := 100;
  asm
    mov eax, g_result
    %if x
      add eax, 1
    %endif
    mov g_result, eax
  end;
  writeln(g_result);
end;

begin
  foo(true);
  foo(false);
end.
