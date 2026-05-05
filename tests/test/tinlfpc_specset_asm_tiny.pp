{ %OPT=-Si }
{ %RESULT=0 }
program tinlfpc_specset_asm_tiny;
{$mode objfpc}{$asmmode intel}
procedure foo(x: boolean specialize [true, false]);
begin
  asm
    nop
  end;
end;
begin
  foo(true);
  foo(false);
end.
