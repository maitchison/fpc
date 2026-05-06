{ %OPT=-Si }
{ %RESULT=42 }
{
  Normal (non-asm) Pascal inline w/ default-valued params.

  ncal.pas around line 4391-4420 fills missing optional args with
  genconstsymtree(defaultconstsym) BEFORE pass1_inline runs
  replaceparaload, so the call node arrives at the splice with a
  full argnode chain. No special handling required for normal inline.

  Test exercises three call shapes:
    add(a, b, c) -- all explicit
    add(a, b)    -- omit 1 default
    add(a)       -- omit 2 defaults
  Sums are checked against expected values; final RESULT=42 confirms
  every call returned the right number.
}
program tinlfpc_default_param_normal;

{$mode objfpc}
{$INLINE ON}

function add(a: longint; b: longint = 10; c: longint = 100): longint; inline;
begin
  result := a + b + c;
end;

var
  r1, r2, r3: longint;
begin
  r1 := add(1, 2, 3);    { 6 }
  r2 := add(1, 2);       { 1+2+100 = 103 }
  r3 := add(1);          { 1+10+100 = 111 }
  if r1 <> 6   then halt(91);
  if r2 <> 103 then halt(92);
  if r3 <> 111 then halt(93);
  halt(42);
end.
