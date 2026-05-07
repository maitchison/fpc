{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ Smoke: -OoSCHEDULE option parses cleanly and the scheduler
  pass runs without breaking simple integer code. The scheduler
  early-exits on non-PMMX targets; -OpPENTIUMMMX puts us on the
  active path. We don't assert any reorder happened -- just that
  enabling the flag doesn't miscompile a basic program. }
{$mode objfpc}
program tinlfpc_pmmx_scheduler;

var
  a, b, c: longint;
begin
  a := 3;
  b := 4;
  c := a + b;
  if c <> 7 then halt(1);
  c := c * 2;
  if c <> 14 then halt(2);
  c := c - 1;
  if c <> 13 then halt(3);
end.
