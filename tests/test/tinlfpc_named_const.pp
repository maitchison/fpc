{ %OPT=-Si -OoNAMEDARGS }
{ %RESULT=0 }
{
  Named args with const/var/out params and string types -- exercises the
  per-candidate type matching after slot reorder.
}
program tinlfpc_named_const;

{$mode objfpc}{$H+}

procedure setpair(const tag: string; out value: longint; multiplier: longint = 10);
begin
  if tag = 'a' then value := 1 * multiplier
  else if tag = 'b' then value := 2 * multiplier
  else value := 0;
end;

var
  v: longint;
begin
  setpair('a', v);                     { all positional }
  if v <> 10 then halt(1);

  setpair(value := v, tag := 'b');     { both named, swapped order }
  if v <> 20 then halt(2);

  setpair('a', v, multiplier := 100);  { positional + named at the end }
  if v <> 100 then halt(3);

  setpair(tag := 'b', multiplier := 5, value := v);
  if v <> 10 then halt(4);
end.
