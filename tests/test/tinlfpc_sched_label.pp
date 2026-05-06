{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Label / control-flow boundary: the scheduler must treat labels and
  jumps as hard barriers. A bug here would either reorder past a
  branch (semantic break), or produce a target-distance error that
  the assembler fails to encode.

  Loops with non-trivial bodies, conditional skip, early exit -- a
  spread of CF shapes for the scheduler to walk through.
}
program tinlfpc_sched_label;

function counted_sum(limit: longint): longint;
var
  i, s: longint;
begin
  s := 0;
  for i := 1 to limit do
    begin
      if (i mod 3) = 0 then continue;
      if i > 100 then break;
      s := s + i;
    end;
  counted_sum := s;
end;

var
  v: longint;
begin
  v := counted_sum(10);
  { 1+2+4+5+7+8+10 = 37 }
  if v <> 37 then halt(1);
  v := counted_sum(20);
  { 1+2+4+5+7+8+10+11+13+14+16+17+19+20 = 147 }
  if v <> 147 then halt(2);
  v := counted_sum(150);
  { sums 1..100 minus multiples-of-3, then break at i=101.
    sum 1..100 = 5050; multiples of 3 in 1..100 = 3+6+...+99 = 1683
    => 5050 - 1683 = 3367.  Loop processes through i=100; at i=101 we
    break before adding it. }
  if v <> 3367 then halt(3);
end.
