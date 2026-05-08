{ %OPT=-OpPENTIUMMMX -O2 }
{ %RESULT=0 }

{ Sanity check that the Pentium/PentiumMMX peephole rewrite of
  MOV $-1, %reg into OR $-1, %reg preserves semantics across sizes. }

program tinlfpc_p5_movm1;

{$mode objfpc}{$h+}

procedure check(expected, actual: int64; tag: string);
  begin
    if actual <> expected then
      begin
        writeln('FAIL ', tag, ': expected ', expected, ' got ', actual);
        halt(1);
      end;
  end;

var
  l: longint;
  w: word;
  q: int64;
begin
  l := -1;
  check(-1, l, 'l');

  w := word(-1);
  check($ffff, w, 'w');

  q := -1;
  check(-1, q, 'q');

  { Verify subsequent flag-clobbering uses still work. }
  l := -1;
  if l = -1 then
    check(0, 0, 'cmp_eq')
  else
    halt(2);

  writeln('OK');
end.
