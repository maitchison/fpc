{ %OPT=-Si -OoNAMEDARGS }
{ %RESULT=0 }
{
  Overload selected by named arg vs positional. Two overloads with
  different argument shapes; named args route to the matching overload.
}
program tinlfpc_named_overload;

{$mode objfpc}

function foo(a: longint; flag: boolean = false): longint; overload;
begin
  if flag then result := a + 1 else result := a;
end;

function foo(a, b: longint): longint; overload;
begin
  result := a + b;
end;

var
  r: longint;
begin
  r := foo(10, flag := true);
  if r <> 11 then halt(1);

  r := foo(10);
  if r <> 10 then halt(2);

  r := foo(10, 5);
  if r <> 15 then halt(3);
end.
