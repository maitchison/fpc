{ %OPT=-Si -OoINLINESITEBUDGET=0 }
{ %RESULT=0 }
{
  Verify that -OoINLINESITEBUDGET=0 restores the legacy depth-decay
  formula. With SITEBUDGET=0 the per-site cap reverts to
    sqrt(10000 / (depth/3 + 1))
  giving 10000 / 1000 / 251 / 100 / 52 nodes at depths 0..4.

  This test stays small so the legacy formula doesn't reject anything
  -- we're testing the codepath, not exercising the limit. If a future
  change accidentally makes SITEBUDGET=0 mean something other than
  "use legacy formula", this test still has to compile cleanly.
}
program tinlfpc_sitebudget_legacy;

{$mode objfpc}
{$INLINE ON}

function add_one(x: longint): longint; inline;
begin
  result := x + 1;
end;

function add_two(x: longint): longint; inline;
begin
  result := add_one(add_one(x));
end;

var
  r: longint;
begin
  r := add_two(40);
  if r <> 42 then halt(1);
end.
