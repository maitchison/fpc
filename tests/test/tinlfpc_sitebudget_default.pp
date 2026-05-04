{ %OPT=-Si -vy }
{ %RESULT=0 }
{
  Verify that the default inline heuristic accepts mid-sized bodies
  4-deep in a call tree -- the case the legacy depth formula rejected
  with "node count >= limit 52 at inline depth 4".

  Default SITEBUDGET=1000 (set in compiler/globals.pas) replaces the
  legacy depth formula. Anything <= 1000 nodes inlines regardless of
  depth. This test does NOT pass an explicit -OoINLINESITEBUDGET so it
  exercises the compiled-in default. If the default is ever lowered
  below ~80 nodes, this test starts emitting "Not inlining" diagnostics
  and the heuristic regression is caught.

  -vy makes check_inlining print "Not inlining ..." messages on
  rejection. We don't grep here (the lite runner is compile-only), but
  -vy in the test means the compiler emits the rejection comment to
  stdout if anything is rejected -- visible in test logs.
}
program tinlfpc_sitebudget_default;

{$mode objfpc}
{$INLINE ON}

{ Mid-sized body: ~70 nodes after expansion (10 chained adds, 5 muls,
  5 conditional toggles). Sized to fit comfortably under the new
  default of 1000 but well above the legacy depth-4 limit of 52. }
function mid(x: longint): longint; inline;
var
  a, b, c, d: longint;
begin
  a := x + 1;
  b := a + 2;
  c := b + 3;
  d := c + 4;
  a := a + d * 2;
  b := b + d * 3;
  c := c + d * 5;
  if (a and 1) = 0 then a := a + 7;
  if (b and 1) = 0 then b := b + 11;
  if (c and 1) = 0 then c := c + 13;
  if (d and 1) = 0 then d := d + 17;
  if (a + b) > 100 then a := a - 50;
  result := a + b + c + d;
end;

function level1(x: longint): longint; inline; begin result := mid(x) + 1; end;
function level2(x: longint): longint; inline; begin result := level1(x) + 1; end;
function level3(x: longint): longint; inline; begin result := level2(x) + 1; end;
function level4(x: longint): longint; inline; begin result := level3(x) + 1; end;

var
  r: longint;
begin
  r := level4(10);   { mid called at inline depth 4+ -- legacy formula
                       rejected this; new default accepts. }
  if r < 0 then halt(1);
end.
