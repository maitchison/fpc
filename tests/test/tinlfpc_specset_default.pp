{ %OPT=-Si }
{ %RESULT=0 }
program tinlfpc_specset_default;
{$mode objfpc}

{ Spec-set parameter with a default value: callers must be able to
  omit the optional argument. Pre-fix, pspecset's dispatch stub
  dropped the user's `= <default>' so `dith()' / `flag()' failed
  with "Wrong number of parameters specified". }

procedure flag(b: boolean specialize [true, false] = true);
begin
  if b then
    write('T')
  else
    write('F');
end;

procedure dith(k: integer specialize [1, 4, 8] = 4);
begin
  case k of
    1: write('1');
    4: write('4');
    8: write('8');
  end;
end;

begin
  flag;          { default true  -> T }
  flag(false);   { explicit      -> F }
  flag(true);    { explicit      -> T }
  dith;          { default 4     -> 4 }
  dith(1);       { explicit      -> 1 }
  dith(8);       { explicit      -> 8 }
  writeln;
  if ParamCount = -1 then halt(1); { suppress unused-param warning, never taken }
end.
