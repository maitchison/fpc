{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{
  Regression: an `assembler; nostackframe; inline;` proc declared with a
  non-register calling convention (e.g. stdcall) used to be silently
  rejected by paraloc_is_single_intreg failing on stack-passed paras.
  The diagnostic was confusing: "param X not in single int register"
  rather than the actual reason.

  After today's psub.pas patch, an explicit pocall_register gate emits
  "calling convention is not register (got pocall_stdcall)" which is
  much clearer. The compiler must NOT crash when it encounters such a
  proc -- it should fall back to a normal CALL.

  Compile-only test. If compile succeeds (compiler doesn't crash), pass.
}
program tinlfpc_register_cc_gate;

{$INLINE ON}
{$asmmode intel}

{ stdcall + assembler + nostackframe + inline: paraloc isn't single
  intreg, gate must reject cleanly without compiler crash. Body kept
  trivial since it won't actually be inlined. }
function add_one(x: longint): longint; stdcall; assembler; nostackframe; inline;
asm
  mov eax, [esp+4]
  inc eax
  ret 4
end;

var
  r: longint;
begin
  r := add_one(41);
  if r <> 42 then halt(1);
end.
