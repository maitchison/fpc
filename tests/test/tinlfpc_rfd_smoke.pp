{ %OPT=-Si }
{ %RESULT=0 }
{
  Smoke test for `managed record` with field defaults. After a local var
  declaration, the synthesised class operator Initialize should fire on
  routine entry and set each field to its declared default.
}
program tinlfpc_rfd_smoke;

{$mode objfpc}{$modeswitch advancedrecords}

type
  tFrameHeader = packed managed record
    magic:   dword = $DEADBEEF;
    version: byte = 1;
    format:  byte = 0;
    flags:   word = 17;
  end;

var
  h: tFrameHeader;
begin
  if h.magic   <> $DEADBEEF then halt(1);
  if h.version <> 1         then halt(2);
  if h.format  <> 0         then halt(3);
  if h.flags   <> 17        then halt(4);
  halt(0);
end.
