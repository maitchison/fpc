{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Scheduler basic-correctness test: the post-peephole U/V scheduler
  must not change the observable result of arithmetic. With
  -OpPENTIUMMMX and -OoSCHEDULE the scheduler is active; a bug that
  swaps two dependent ops would change the computed value.
}
program tinlfpc_sched_arith;

var
  a, b, c, d, e, f: longint;
begin
  a := 7;
  b := a * 3;            { 21 }
  c := b - 5;            { 16 }
  d := c and $f0;        { 16 }
  e := d or 1;           { 17 }
  f := e xor a;          { 17 xor 7 = 22 }
  if f <> 22 then halt(1);
  { Independent chain: scheduler may reorder these; result must
    still match. }
  a := 100;
  b := 200;
  c := 300;
  d := 400;
  if (a + b + c + d) <> 1000 then halt(2);
end.
