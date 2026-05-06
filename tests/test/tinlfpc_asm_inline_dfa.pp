{ %OPT=-O3 -OoINLINESITEBUDGET=1000 -Si -CpPENTIUMMMX -OpPENTIUMMMX }
{ %RESULT=0 }
{
  Test for v6 asmnf_inline_splice / DFA-on-callers.

  Pre-fix: splicing a pure-asm helper into a Pascal caller set
  pi_has_assembler_block on the caller via tasmnode.pass_typecheck,
  causing DFA + const-prop + dead-store-elim to bail on the entire
  caller proc.

  Post-fix: cloned asmnodes (the ones produced by inline_clone_asm_
  labels at splice time) carry asmnf_inline_splice in asmnodeflags,
  pass_typecheck recognises it, pi_has_assembler_block stays clear,
  DFA runs.

  Correctness check below: the Pascal-side computation surrounding
  the asm splice must still produce the right answer regardless of
  whether DFA ran. If asmnf_inline_splice was set by mistake on a
  user-written asm block (or pi_has_assembler_block stays set when
  it shouldn't), DFA will still bail or run -- in either case the
  arithmetic must work out, since these tests don't depend on the
  optimisation level.
}
program tinlfpc_asm_inline_dfa;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

function add3(a, b, c: longint): longint; assembler; nostackframe; inline;
asm
  add eax, edx
  add eax, ecx
end;

function shift1(x: longint): longint; assembler; nostackframe; inline;
asm
  shl eax, 1
end;

{ Pascal proc with non-trivial control flow + inline-asm splice in
  the middle. DFA should still flow constants from `if k = 5` through
  to the post-splice block. The asm splice doesn't propagate constants
  through itself (asmn is a barrier in optconstprop) but anything
  above and below the splice still gets analysed. }
function compute(k, x: longint): longint;
var
  a, b: longint;
begin
  if k = 5 then
    a := 100
  else
    a := 200;
  b := add3(a, x, x);   { spliced inline-asm in the middle }
  if k > 0 then
    result := shift1(b)
  else
    result := b;
end;

{ Loop body inlines an asm helper many times. With DFA enabled across
  the splice boundary, the Pascal-side index-bound check should still
  collapse / hoist out of the loop. Without DFA, the loop still works
  -- this is a correctness test, not a perf test. }
function sum_first_n(n: longint): longint;
var
  i, total: longint;
begin
  total := 0;
  for i := 1 to n do
    total := add3(total, i, 0);
  result := total;
end;

var
  i, sum: longint;
begin
  if compute(5, 7)  <> shift1(100 + 7 + 7) then halt(1);
  if compute(5, 0)  <> shift1(100) then halt(2);
  if compute(0, 3)  <> 200 + 3 + 3 then halt(3);
  if compute(-1, 1) <> 200 + 1 + 1 then halt(4);

  { 1+2+...+10 = 55 }
  if sum_first_n(10) <> 55 then halt(5);
  if sum_first_n(0) <> 0 then halt(6);
  if sum_first_n(1) <> 1 then halt(7);

  { Const-folded exhaustive coverage. }
  sum := 0;
  for i := 1 to 100 do
    sum := add3(sum, i, 0);
  if sum <> (100 * 101) div 2 then halt(8);
end.
