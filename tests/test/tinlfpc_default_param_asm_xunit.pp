{ %OPT=-OoINLINESITEBUDGET=1000 -OoASMINLINE -Si }
{ %RESULT=0 }
{
  Cross-unit asm-inline w/ a default-valued parameter. Forces the
  inlininginfo body to round-trip through the providing unit's .ppu
  before the consumer splices it -- this is the path the original
  uuchar.pp/system.ppu PPU writer crash described at
  is_assembler_inlineable:368-376 hit before the gate guarded against
  it. The gate is now obsolete (the underlying ttemprefnode/PPU writer
  bug was fixed by fix/asm-inline-ppu-roundtrip) so the splice should
  succeed cleanly cross-unit.
}
program tinlfpc_default_param_asm_xunit;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

uses udefparam;

var
  a, b: longint;
begin
  a := add_def(10, 7);
  if a <> 17 then halt(1);

  b := add_def(10);
  if b <> 15 then halt(2);
end.
