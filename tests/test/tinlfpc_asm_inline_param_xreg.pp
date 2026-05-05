{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{
  Positive control for the param-symbol cross-register fix:
  asmnode_inline_safe + inline_resolve_asm_paralocals (compiler/psub.pas
  + compiler/nbas.pas) accept a top_local operand that names a parameter
  whose calleeside paraloc is a single integer register, and rewrite it
  to top_reg of that register at splice time.

  Three sites exercised:

    * `mov ebx, slot` -- cross-register read of a 32-bit longint param
      whose home is EAX. Before the fix, the asm reader emits top_local
      and the gate trips; after the fix, the splice rewrites it to
      `mov ebx, eax` and the body inlines into the caller.

    * `mov ecx, slot` -- second cross-reg destination, makes sure the
      rewrite is per-operand (not just first-instruction-only) and works
      from a different scratch reg.

    * `mov eax, slot` -- self-mov on the home register. Already worked
      pre-fix because the reader collapses it to top_reg directly; kept
      here as a regression guard so a future change to the predicate
      doesn't accidentally exclude self-mov.

  Compile-and-run check: each helper writes its observed slot value to
  a sentinel slot in a global array; main verifies the values match the
  arguments passed at the call site. If the rewrite mistakenly maps the
  param symbol to the wrong register (or a stack frame the caller doesn't
  have), the sentinel won't equal the argument and the test halts.

  Inspect tinlfpc_asm_inline_param_xreg.s with -al -an to confirm the
  call sites contain spliced bodies (no `call P$..._$$_X_VIA_EBX$
  LONGINT$$LONGINT` etc.) and -vd should not print any "Inline
  disabled" / "Not inlining" lines for these helpers. }
program tinlfpc_asm_inline_param_xreg;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

var
  observed: array[0..15] of longint;

function x_via_ebx(slot: longint): longint; assembler; nostackframe; inline;
asm
  push ebx
  mov  ebx, slot       { cross-reg read: top_local -> top_reg(EAX) at splice }
  mov  eax, ebx
  pop  ebx
end;

function x_via_ecx(slot: longint): longint; assembler; nostackframe; inline;
asm
  push ecx
  mov  ecx, slot       { same shape, different scratch register }
  mov  eax, ecx
  pop  ecx
end;

function x_via_eax(slot: longint): longint; assembler; nostackframe; inline;
asm
  mov  eax, slot       { self-mov: already worked pre-fix, regression guard }
end;

procedure record_observed(idx, value: longint); assembler; nostackframe; inline;
asm
  push ebx
  mov  ebx, idx        { another cross-reg read, this time of a 2-para proc }
  mov  [observed + ebx*4], value
  pop  ebx
end;

var
  i: longint;
begin
  for i := 0 to high(observed) do
    observed[i] := -1;

  if x_via_ebx(11) <> 11 then halt(1);
  if x_via_ecx(22) <> 22 then halt(2);
  if x_via_eax(33) <> 33 then halt(3);

  record_observed(0, 100);
  record_observed(1, 200);
  record_observed(2, 300);
  if observed[0] <> 100 then halt(4);
  if observed[1] <> 200 then halt(5);
  if observed[2] <> 300 then halt(6);

  { Compose: nested splices on cross-register paths. }
  if x_via_ebx(x_via_ecx(7)) <> 7 then halt(7);
end.
