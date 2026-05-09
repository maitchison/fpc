{ %OPT=-O3 -OoINLINESITEBUDGET=1000 -OoASMINLINE -Si -CpPENTIUMMMX -OpPENTIUMMMX }
{ %RESULT=0 }
{
  Cross-unit version of tinlfpc_asm_inline_dfa. Imports inline-asm
  helpers from udfaunit so call sites go through the ppuload-based
  splice path where pass_typecheck actually fires on the cloned
  asmnode in the caller's procinfo. With v6 asmnf_inline_splice
  in place, pi_has_assembler_block stays clear on the caller and
  DFA can run.

  Correctness check: Pascal-side computations around cross-unit
  splices must produce identical results to the same-unit version.
}
program tinlfpc_asm_inline_dfa_xunit;

{$mode objfpc}
{$INLINE ON}

uses udfaunit;

function compute(k, x: longint): longint;
var
  a, b: longint;
begin
  if k = 5 then
    a := 100
  else
    a := 200;
  b := add3(a, x, x);
  if k > 0 then
    result := shift1(b)
  else
    result := b;
end;

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

  if sum_first_n(10) <> 55 then halt(5);
  if sum_first_n(0) <> 0 then halt(6);
  if sum_first_n(1) <> 1 then halt(7);

  sum := 0;
  for i := 1 to 100 do
    sum := add3(sum, i, 0);
  if sum <> (100 * 101) div 2 then halt(8);
end.
