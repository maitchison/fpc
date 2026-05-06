{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{
  Jump-length stress: a large basic block bracketed by a conditional
  branch. If the scheduler accidentally reorders past the branch, or
  changes the byte length of the instructions inside, the assembler
  may fail to encode short / near jumps.

  We stuff the block with independent arithmetic to maximize the
  number of swap candidates the scheduler sees.
}
program tinlfpc_sched_jumplen;

var
  a, b, c, d, e, f, g, h: longint;

procedure crank(seed: longint);
begin
  if seed = 0 then exit;
  a := seed * 1;
  b := seed * 2;
  c := seed * 3;
  d := seed * 4;
  e := a + b;
  f := c + d;
  g := e + f;
  h := g xor seed;
  a := a + 1;
  b := b + 1;
  c := c + 1;
  d := d + 1;
  e := e or 1;
  f := f or 2;
  g := g or 4;
  h := h or 8;
  if h = 0 then halt(99);
end;

begin
  crank(7);
  if a <> 8 then halt(1);
  if b <> 15 then halt(2);
  if c <> 22 then halt(3);
  if d <> 29 then halt(4);
  if (e and 1) = 0 then halt(5);
  if (f and 2) = 0 then halt(6);
  if (g and 4) = 0 then halt(7);
  if (h and 8) = 0 then halt(8);
  crank(0);
  { after crank(0) globals stay at the values from crank(7) }
  if a <> 8 then halt(11);
end.
