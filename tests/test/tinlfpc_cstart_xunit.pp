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

  Post-fix:
    * tcompilerppufile.putasmsymbol/getasmsymbol now round-trip name +
      bind + typ via aasmbase.lookup_inline_asm_pool_by_name, a
      process-global pool of stable TAsmSymbol identities (symtype.pas).
    * pmodules.finish_unit calls nbas.freeze_inline_asm_body on every
      pio_inline_asm procdef in the unit BEFORE module.end_of_parsing
      drops its asmdata, replacing the body's about-to-dangle pointers
      with the same pool entries the cross-run case sees.
    * nbas.clone_one_asmnode_labels at splice time runs each non-AB_LOCAL
      pool entry through current_asmdata.RefAsmSymbol so the consumer
      gets a real AB_EXTERNAL reference; AB_LOCAL pool entries fall
      through to the existing label-rename path which substitutes a
      fresh getjumplabel result.
  Cross-unit asm-inline now actually inlines instead of falling back to
  CALL.

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
