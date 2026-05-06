{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Flag-dependency hazard: cmp / test followed by jcc must not be
  separated by the scheduler. A reorder that inserts a flag-clobbering
  instruction between them silently turns a conditional branch on
  the wrong flags.
}
program tinlfpc_sched_flagdep;

function classify(x: longint): longint;
var
  y: longint;
begin
  y := x and $ff;
  if x > 0 then
    classify := y + 1
  else
    classify := y - 1;
end;

var
  i: longint;
  pos_count, neg_count, zero_count: longint;
begin
  pos_count  := 0;
  neg_count  := 0;
  zero_count := 0;
  for i := -5 to 5 do
    begin
      if i > 0 then
        begin
          if classify(i) <> (i and $ff) + 1 then halt(20);
          inc(pos_count);
        end
      else if i < 0 then
        begin
          if classify(i) <> (i and $ff) - 1 then halt(30);
          inc(neg_count);
        end
      else
        begin
          { i = 0 -> classify takes the else branch -> y=0, returns -1 }
          if classify(0) <> -1 then halt(10);
          inc(zero_count);
        end;
    end;
  if pos_count  <> 5 then halt(40);
  if neg_count  <> 5 then halt(50);
  if zero_count <> 1 then halt(60);
end.
