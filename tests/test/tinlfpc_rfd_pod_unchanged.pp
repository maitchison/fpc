{ %OPT=-Si }
{ %RESULT=0 }
{
  Verify that an ordinary (non-managed) packed record still compiles fine
  with no field defaults -- the change must be opt-in, never silent. We
  manually FillChar to make the test deterministic.
}
program tinlfpc_rfd_pod_unchanged;

{$mode objfpc}{$modeswitch advancedrecords}

type
  tBlitTile = packed record
    pixels: array[0..3] of byte;
  end;

var
  t: tBlitTile;
begin
  FillChar(t, sizeof(t), 0);
  if t.pixels[0] = 0 then
    if t.pixels[3] = 0 then
      halt(0);
  halt(1);
end.
