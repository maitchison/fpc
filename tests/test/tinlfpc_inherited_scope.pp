{ %OPT=-Si }
{ %RESULT=0 }
{ Minimal repro: inherited property + virtual method + override that
  references the inherited property from inside its body. Mirrors the
  shape of dev/shared/uVesaDriver.pas:setLogicalSize where the body
  reports "Identifier not found bitsPerPixel/videoMemory/fLogicalWidth"
  even though they are inherited public members.

  If this fails to compile, we have an isolated repro of the bug; if
  it compiles, the bug is specific to a wider context (multi-unit
  parser-state leakage). }
{$mode objfpc}
program tinlfpc_inherited_scope;

type
  tParent = class
  protected
    fBPP: word;
    fLogicalWidth, fLogicalHeight: word;
  public
    constructor create();
    property bitsPerPixel: word read fBPP;
    procedure setLogicalSize(width, height: word); virtual;
    function videoMemory: dword; virtual;
  end;

  tChild = class(tParent)
  public
    procedure setLogicalSize(width, height: word); override;
    function videoMemory: dword; override;
  end;

constructor tParent.create();
  begin
    fBPP := 16;
    fLogicalWidth := 320;
    fLogicalHeight := 240;
  end;

procedure tParent.setLogicalSize(width, height: word);
  begin
    fLogicalWidth := width;
    fLogicalHeight := height;
  end;

function tParent.videoMemory: dword;
  begin
    result := 1024 * 1024;
  end;

procedure tChild.setLogicalSize(width, height: word);
  var
    actualWidth: word;
  begin
    if (width * height * bitsPerPixel div 8) > videoMemory then halt(1);
    actualWidth := width;
    fLogicalWidth := actualWidth;
    fLogicalHeight := height;
  end;

function tChild.videoMemory: dword;
  begin
    result := 4 * 1024 * 1024;
  end;

var
  c: tChild;
begin
  c := tChild.create;
  c.setLogicalSize(640, 480);
  if c.fLogicalWidth <> 640 then halt(2);
  if c.fLogicalHeight <> 480 then halt(3);
  c.free;
end.
