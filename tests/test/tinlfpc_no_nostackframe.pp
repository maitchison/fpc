{ %OPT=-OoINLINESITEBUDGET=1000 -OoASMINLINE -Si }
{ %RESULT=0 }
{
  Regression: an `assembler; inline;` proc without `nostackframe` was
  parsed and its body stored as inlininginfo. is_assembler_inlineable
  rejected the splice via pio_inline_not_possible, but
  ncal.check_inlining did NOT consult that flag, so cnf_do_inline was
  set, pass1_inline ran, and the splice crashed because the body still
  contained a prologue/epilogue.

  Fix lives in compiler/ncal.pas: check_inlining bails when
  pio_inline_not_possible is set. Without the fix this file crashes the
  compiler. With the fix it compiles cleanly and the call falls back to
  a normal CALL instruction.

  Compile-only test -- no runtime verification needed. If the compiler
  doesn't crash, we pass.
}
program tinlfpc_no_nostackframe;

{$INLINE ON}
{$asmmode intel}

function add_one(x: longint): longint; assembler; inline;
asm
  mov eax, x
  inc eax
  { No `nostackframe` -- compiler emits a prologue/epilogue. Pre-fix:
    pass1_inline tries to splice the body anyway and crashes. }
end;

var
  r: longint;
begin
  r := add_one(41);
  if r <> 42 then halt(1);
end.
