{ %OPT=-O3 -OoINLINESITEBUDGET=1000 -CpPENTIUMMMX -OpPENTIUMMMX -Si }
{ %RESULT=0 }
{
  Cross-unit version of the zagZig repro: declared in a unit's interface
  with `inline; register; assembler;`, called from main program. Mirrors
  the dev/shared/uUtils.pas zagZig setup (Delphi mode + int32 + register).
}
program tinlfpc_zagzig_xunit;

{$MODE DELPHI}
{$INLINE ON}

uses uzagunit;

var
  r: int32;
begin
  r := zagZig(0);
  if r <> 0 then halt(1);
  r := zagZig(1);
  if r <> -1 then halt(2);
  r := zagZig(2);
  if r <> 1 then halt(3);
  r := zagZig(3);
  if r <> -2 then halt(4);
  r := zagZig(4);
  if r <> 2 then halt(5);
end.
