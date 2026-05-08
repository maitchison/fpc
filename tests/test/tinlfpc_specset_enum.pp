{ %OPT=-Si }
{ %RESULT=0 }
program tinlfpc_specset_enum;
{$mode objfpc}

type
  tMode = (mOff, mOn, mDebug);

procedure run(m: tMode specialize [mOff, mOn, mDebug]; n: longint);
begin
  case m of
    mOff:   writeln('off ', n);
    mOn:    writeln('on ', n);
    mDebug: writeln('dbg ', n);
  end;
end;

var
  v: tMode;
begin
  { constant call sites: stub inlines to direct wrapper call. }
  run(mOff,   1);
  run(mOn,    2);
  run(mDebug, 3);

  { runtime call site: stub stays as case-table dispatch. }
  v := mDebug;
  run(v, 4);
end.
