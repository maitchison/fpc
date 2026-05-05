{ %OPT=-Si }
{ %RESULT=0 }
program tinlfpc_specset_baseline;
{$mode objfpc}

procedure foo(x: boolean specialize [true, false]);
begin
  if x then
    writeln('true')
  else
    writeln('false');
end;

begin
  foo(true);
  foo(false);
end.
