{ %OPT=-Si }
{ %RESULT=0 }
{ Repro: when a child class redeclares a parent method with a
  different signature (with `overload` or `reintroduce`), subsequent
  class member declarations may be silently dropped from the child's
  class symtable -- their impl bodies then compile in a non-method
  context, breaking inherited-member resolution and `inherited`.

  Concretely mirrors dev/shared/uVesaDriver.pas: parent has
  setMode(width, height, bpp), child has setMode(mode: word) marked
  reintroduce, child also declares setLogicalSize as override --
  setLogicalSize body fails to find inherited members. }
{$mode objfpc}
program tinlfpc_class_overload_corrupt;

type
  tParent = class
  protected
    fBPP: word;
    fLogicalWidth, fLogicalHeight: word;
  public
    constructor create();
    property bitsPerPixel: word read fBPP;
    procedure setMode(width, height, bpp: word);     { 3-arg, no overload }
    procedure setLogicalSize(width, height: word); virtual;
    function videoMemory: dword; virtual;
  end;

  tChild = class(tParent)
  public
    procedure setMode(mode: word); reintroduce;       { 1-arg, hides parent's }
    procedure setLogicalSize(width, height: word); override;
    function videoMemory: dword; override;
  end;

constructor tParent.create();
  begin
    fBPP := 16;
    fLogicalWidth := 320;
    fLogicalHeight := 240;
  end;

procedure tParent.setMode(width, height, bpp: word);
  begin
    fLogicalWidth := width;
    fLogicalHeight := height;
    fBPP := bpp;
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

procedure tChild.setMode(mode: word);
  begin
    fBPP := 32;
  end;

procedure tChild.setLogicalSize(width, height: word);
  begin
    if (width * height * bitsPerPixel div 8) > videoMemory then halt(1);
    fLogicalWidth := width;
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
  c.free;
end.
