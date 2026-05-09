{ %OPT=-OoINLINESITEBUDGET=1000 -OoASMINLINE -Si }
{ %RESULT=0 }
{
  Test for v4(a) constant-arg specialisation. When the caller passes
  an integer literal (or `nil`) to a register-cc parameter of a
  pure-asm `inline` proc, the splice path skips the temp + assignment
  + rcd_load triple and emits a direct `mov ABIreg, $imm` via
  cregcapturenode.create_const.

  This test verifies value correctness across the constant fold:
  a wrong fold would either drop the constant, sign-extend it
  incorrectly (1- and 2-byte cases below), or load it into the
  wrong register. We exercise mixed sites where some args are
  constants and some are runtime values, and where multiple
  constants of different widths arrive in different home registers.
}
program tinlfpc_asm_inline_constfold;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

function add3(a, b, c: longint): longint; assembler; nostackframe; inline;
asm
  { para a is in EAX (home), b in EDX, c in ECX.
    Constants for any of these should arrive directly in their
    home reg via rcd_load_const. }
  add eax, edx
  add eax, ecx
end;

function or_byte(x: byte; mask: byte): byte; assembler; nostackframe; inline;
asm
  { 1-byte para. AL holds x, DL holds mask. Constants must
    fit in AL/DL after the const fold. }
  or  al, dl
end;

function or_word(x: word; mask: word): word; assembler; nostackframe; inline;
asm
  { 2-byte para variant -- ax/dx home regs. }
  or  ax, dx
end;

function load_or_zero(p: pointer; idx: longint): longint; assembler; nostackframe; inline;
asm
  { p in EAX, idx in EDX. When called with `nil`, EAX must
    actually be 0 -- niln folding test. We don't deref nil
    in the body; we just read p back to verify the load. }
  test eax, eax
  jz   @@iszero
  mov  eax, [eax + edx*4]
  jmp  @@done
@@iszero:
  mov  eax, $deadbeef
@@done:
end;

var
  arr: array[0..3] of longint = ($11, $22, $33, $44);

begin
  { All-constant call: every arg should fold to a direct mov-imm. }
  if add3(10, 20, 30) <> 60 then halt(1);

  { Mixed: first const, last runtime. }
  if add3(100, 200, add3(1, 2, 3)) <> 306 then halt(2);

  { Negative constants -- sign-extension regression check. }
  if add3(-1, -2, -3) <> -6 then halt(3);

  { Byte-width constants. mask = $0f, x = $a0 -> $af. }
  if or_byte($a0, $0f) <> $af then halt(4);

  { Word-width constants. }
  if or_word($1000, $0234) <> $1234 then halt(5);

  { niln fold for pointer arg. }
  if load_or_zero(nil, 0) <> longint($deadbeef) then halt(6);

  { Pointer arg with real address + const idx. }
  if load_or_zero(@arr, 2) <> $33 then halt(7);

  { Const-on-only-some-args at one site. }
  if add3(add3(1,1,1), 0, add3(2,2,2)) <> 9 then halt(8);
end.
