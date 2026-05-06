{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Memory-dependency hazard: a write followed by a read at a
  potentially-aliasing address must not be reordered. The scheduler's
  conservative rule is "any two instructions that touch memory cannot
  be reordered past each other"; this test exercises that path with a
  global-array write then read.
}
program tinlfpc_sched_memdep;

var
  buf: array[0..7] of longint;

begin
  buf[0] := 100;
  buf[1] := 200;
  buf[2] := buf[0] + buf[1];           { 300 }
  buf[3] := buf[2] * 2;                { 600 }
  buf[4] := buf[3] - buf[1];           { 400 }
  buf[0] := buf[4];                    { 400 }
  buf[1] := buf[0] + 50;               { 450 }
  if buf[0] <> 400 then halt(1);
  if buf[1] <> 450 then halt(2);
  if buf[2] <> 300 then halt(3);
  if buf[3] <> 600 then halt(4);
  if buf[4] <> 400 then halt(5);
end.
