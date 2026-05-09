{ %OPT=-Si -OoNAMEDARGS }
{ %RESULT=0 }
{
  The point of named args: skip a middle defaulted parameter without
  having to spell out the value.
}
program tinlfpc_named_default_skip;

{$mode objfpc}

function f(a: longint; b: longint = 99; c: longint = 7): longint;
begin
  result := a*10000 + b*100 + c;
end;

var
  r: longint;
begin
  { fill a + c, leave b at default }
  r := f(1, c := 5);
  if r <> (1*10000 + 99*100 + 5) then halt(1);

  { fill a + b only, c stays at default 7 }
  r := f(1, b := 2);
  if r <> (1*10000 + 2*100 + 7) then halt(2);

  { all defaults except a }
  r := f(1);
  if r <> (1*10000 + 99*100 + 7) then halt(3);

  { mixed: positional a, then both named in reversed order }
  r := f(1, c := 5, b := 2);
  if r <> (1*10000 + 2*100 + 5) then halt(4);
end.
