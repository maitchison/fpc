{ %OPT=-OoINLINESITEBUDGET=1000 -Si -O3 -CpPENTIUMMMX -OpPENTIUMMMX }
{ %RESULT=0 }
{
  Cross-unit asm-inline regression. cStart-style RDTSC helper declared
  `assembler; inline;` (with nostackframe in the implementation) lives in
  ucstartunit; this program calls it across the unit boundary.

  Pre-fix: the body of an asm-inline proc loaded from .ppu still had its
  tasmsymbol pointers from the providing unit's current_asmdata, but that
  asmdata had already been freed by the time the consumer spliced --
  ai.oper[i]^.ref^.symbol pointed at re-used heap memory, causing SIGSEGV
  in inline_clone_asm_labels (DOSBox) and corrupted external-symbol names
  in the .o files (Win32 cross-compile).

  Post-fix (compiler/ncal.pas:check_inlining): cross-unit asm-inline is
  rejected with a clear diagnostic and the call site falls back to a
  normal CALL. Same-unit asm-inline is unaffected (see
  tinlfpc_cstart_inline). Once tcompilerppufile.putasmsymbol /
  getasmsymbol round-trip the symbol via mangled name, this gate can be
  loosened.

  Test: program compiles cleanly (no SIGSEGV, no internalerror, no
  undefined-symbol error from the linker), runs, and observes the timer
  counter advancing after each cStart call.
}
program tinlfpc_cstart_xunit;

{$mode objfpc}
{$INLINE ON}

uses ucstartunit;

var
  t0, t1: uint64;
begin
  fillchar(cycleTimer, sizeof(cycleTimer), 0);
  cStart(0);
  t0 := cycleTimer[0].startTime;
  cStart(0);
  t1 := cycleTimer[0].startTime;
  if t1 < t0 then halt(1);
  if (t0 = 0) and (t1 = 0) then halt(2);
end.
