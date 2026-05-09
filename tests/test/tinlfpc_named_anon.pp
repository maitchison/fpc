{ %OPT=-Si -OoNAMEDARGS }
{ %RESULT=0 }
{
  Anonymous-function arg with `Result := ...` in its body. Verifies the
  outer arg-list's named-arg parsing does not leak named_args_allowed
  into the anon function's statement parsing -- otherwise `Result := X`
  would be misread as a named arg with name "Result".
}
program tinlfpc_named_anon;

{$mode objfpc}{$modeswitch anonymousfunctions}

type
  tcomparer = function(a, b: longint): boolean;

function apply(c: tcomparer; x, y: longint): longint;
begin
  if c(x, y) then result := 1 else result := 0;
end;

var
  r: longint;
begin
  { positional anon function arg, with `Result :=` inside the body. }
  r := apply(
    function(a, b: longint): boolean
    begin
      Result := a < b;
    end,
    3, 5);
  if r <> 1 then halt(1);
end.
