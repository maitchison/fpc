{ %OPT=-Si }
{ %RESULT=0 }
{ Closer to dev/shared/uVesaDriver.pas:setLogicalSize -- override
  body now contains TWO asm blocks (first one references the param,
  second one references a local). If the bug is triggered by the
  asm-block + inherited-member combination, this will fail to
  compile with "Identifier not found bitsPerPixel/videoMemory". }
{$mode objfpc}
{$asmmode intel}
program tinlfpc_inherited_scope_asm;

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
    asm
      pusha
      mov ax, 1
      mov cx, [width]
      popa
    end;
    fLogicalWidth := width;
    fLogicalHeight := height;
    asm
      pusha
      xor cx, cx
      mov [actualWidth], cx
      popa
    end;
    if actualWidth <> 0 then halt(2);
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
  if c.fLogicalWidth <> 640 then halt(3);
  c.free;
end.
