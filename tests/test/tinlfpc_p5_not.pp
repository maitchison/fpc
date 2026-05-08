{ %OPT=-OpPENTIUMMMX -O2 }
{ %RESULT=0 }

{ Sanity check that the Pentium/PentiumMMX peephole rewrite of NOT %reg
  into XOR $-1, %reg preserves semantics. }

program tinlfpc_p5_not;

{$mode objfpc}{$h+}

procedure check(expected, actual: longint; tag: string);
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
  b: byte;
begin
  l := 5;
  l := not l;
  check(-6, l, 'l1');

  l := 0;
  l := not l;
  check(-1, l, 'l2');

  l := -1;
  l := not l;
  check(0, l, 'l3');

  w := $1234;
  w := not w;
  check(longint($ffff and (not $1234)), w, 'w1');

  b := $a5;
  b := not b;
  check(longint($ff and (not $a5)), b, 'b1');

  writeln('OK');
end.
