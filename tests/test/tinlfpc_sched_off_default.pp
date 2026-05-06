{ %OPT=-OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Default-off behaviour: -OpPENTIUMMMX alone (no -OoSCHEDULE) must
  NOT enable the scheduler. -O2 also must not pull it in. This test
  shares its expectations with sched_arith.pp; if either run breaks
  but the SCHEDULE-on version passes, the gate is wrong.
}
program tinlfpc_sched_off_default;

var
  a, b, c, d, e, f: longint;
begin
  a := 7;
  b := a * 3;
  c := b - 5;
  d := c and $f0;
  e := d or 1;
  f := e xor a;
  if f <> 22 then halt(1);
end.
