{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{
  Same-unit asm-inline w/ a default-valued parameter. Caller-side
  machinery in ncal.pas fills omitted optional args with a
  genconstsymtree(defaultconstsym) loadnode BEFORE pass1_inline runs,
  so the v2(c) hoist+rcd_load path treats it like any other arg.

  Two call sites:
    add_def(10, 7) -> 17    both args explicit
    add_def(10)    -> 15    default 5 substituted

  Regression guard: an earlier gate in is_assembler_inlineable
  rejected any param with defaultconstsym citing a PPU writer bug
  on cross-unit splice; that gate has been removed now that the
  underlying fix/asm-inline-ppu-roundtrip work shipped. If the gate
  comes back -- or some other change rejects defaultconstsym at
  parse-body time -- this test starts emitting "Inline disabled"
  comments for add_def, the splice doesn't happen, and the runtime
  still succeeds (the routine's prologue/epilogue handles call
  fine), so a compile-only run won't catch the regression. Use
  -vy locally to spot the diagnostic.
}
program tinlfpc_default_param_asm_smoke;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

function add_def(x: longint; y: longint = 5): longint; assembler; nostackframe; inline;
asm
  mov eax, x
  add eax, y
end;

var
  a, b: longint;
begin
  a := add_def(10, 7);
  if a <> 17 then halt(1);

  b := add_def(10);
  if b <> 15 then halt(2);
end.
