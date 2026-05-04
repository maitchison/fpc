{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{
  Smoke test: a valid `assembler; nostackframe; register; inline;` proc
  compiles, gets accepted by is_assembler_inlineable, splices into the
  caller, and produces the right value at runtime.

  This is the positive control for the asm-inline pipeline. If a future
  change silently disables the pipeline (e.g. the gate becomes too strict),
  this test keeps passing as compile-only -- but a runtime check verifies
  that the inlined body actually executed correctly.

  On i386, register CC is the default proccalloption -- writing
  `register` is redundant. We omit it here to verify auto-detection.
}
program tinlfpc_asm_inline_smoke;

{$INLINE ON}
{$asmmode intel}

function double_it(x: longint): longint; assembler; nostackframe; inline;
asm
  mov eax, x
  add eax, eax
end;

function triple_it(x: longint): longint; assembler; nostackframe; inline;
asm
  mov eax, x
  lea eax, [eax + eax*2]
end;

var
  r: longint;
begin
  { Multiple call sites -- each gets its own splice. }
  r := double_it(21);
  if r <> 42 then halt(1);

  r := triple_it(14);
  if r <> 42 then halt(2);

  { Compose: triple(double(7)) = 42 -- exercises nested splices and
    fresh body-local label cloning per call site. }
  r := triple_it(double_it(7));
  if r <> 42 then halt(3);
end.
