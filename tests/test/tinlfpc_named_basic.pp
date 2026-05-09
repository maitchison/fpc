{ %OPT=-Si }
{ %RESULT=0 }
program tinlfpc_named_basic;

{$mode objfpc}

function f(a, b, c: longint): longint;
begin
  result := a*100 + b*10 + c;
end;

var
  r: longint;
begin
  r := f(1, c := 3, b := 2);
  if r <> 123 then halt(1);
end.
