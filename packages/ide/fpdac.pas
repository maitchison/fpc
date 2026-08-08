{
    This file is part of the Free Pascal Integrated Development Environment
    Copyright (c) 2026

    Text-mode colour overrides via the VGA DAC

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}

{ Redefines what the sixteen text-mode colours actually look like.

  The palette the IDE edits in Options|Environment|Colors picks from sixteen
  fixed colours; it cannot make a colour that is not already in the set. There
  is exactly one blue, so "a darker blue background" is only reachable by
  reprogramming the DAC entry that blue points at.

  Values live in fp.ini so they can be tuned without a rebuild:

    [Screen]
    Color1=0,0,28        ; blue -- the default editor background
    Color14=63,63,21     ; yellow

  Components are the VGA's native 0..63. Colour numbers are the familiar 0..15
  attribute values; the mapping to DAC registers is the standard text-mode one,
  which is not the identity above 5.

  Colour 1 is darkened by default; everything else is left at its BIOS value
  unless fp.ini says otherwise.

  The BIOS reloads the default DAC on every mode set, so Apply must be called
  again after any mode change, and Restore before handing the screen to DOS. }
unit FPDac;

{$ifdef cpullvm}
{$modeswitch nestedprocvars}
{$endif}
{$H-}

interface

{ reads fp.ini and applies whatever it finds }
procedure InitIDEPalette;
{ re-applies the loaded overrides; call after any video mode set }
procedure ApplyIDEPalette;
{ puts the overridden colours back to their BIOS defaults }
procedure RestoreDefaultPalette;

implementation

uses
  WINI,WUtils,FPVars,FPUtils;

const
  { attribute colour 0..15 -> DAC register, standard VGA text-mode mapping }
  DacOfAttr : array[0..15] of byte =
    ($00,$01,$02,$03,$04,$05,$14,$07,$38,$39,$3A,$3B,$3C,$3D,$3E,$3F);

  { BIOS defaults, 0..63 per component }
  DefaultRGB : array[0..15,0..2] of byte =
    (( 0, 0, 0),( 0, 0,42),( 0,42, 0),( 0,42,42),
     (42, 0, 0),(42, 0,42),(42,21, 0),(42,42,42),
     (21,21,21),(21,21,63),(21,63,21),(21,63,63),
     (63,21,21),(63,21,63),(63,63,21),(63,63,63));

  DacSection = 'Screen';
  DacTag     = 'Color';

var
  OverrideRGB : array[0..15,0..2] of byte;
  Overridden  : array[0..15] of boolean;
  AnyOverride : boolean;

procedure SetDac(Attr,R,G,B : byte);
begin
  portb[$3C8]:=DacOfAttr[Attr];
  portb[$3C9]:=R and 63;
  portb[$3C9]:=G and 63;
  portb[$3C9]:=B and 63;
end;

{ 'r,g,b' with each component 0..63; false if the value is not that shape }
function ParseRGB(S : string; var R,G,B : byte) : boolean;
var
  v    : array[1..3] of longint;
  n,p,e: integer;
begin
  ParseRGB:=false;
  for n:=1 to 3 do
    begin
      p:=Pos(',',S);
      if (p=0) and (n<3) then
        exit;
      if p=0 then
        begin Val(S,v[n],e); S:=''; end
      else
        begin Val(Copy(S,1,p-1),v[n],e); Delete(S,1,p); end;
      if (e<>0) or (v[n]<0) or (v[n]>63) then
        exit;
    end;
  R:=v[1]; G:=v[2]; B:=v[3];
  ParseRGB:=true;
end;

procedure InitIDEPalette;
var
  ini : PINIFile;
  s   : string;
  i   : integer;
  r,g,b : byte;
begin
  for i:=0 to 15 do
    Overridden[i]:=false;

  { Blue is the editor background and the stock one is bright enough to fight
    the text. Put Color1=0,0,42 in fp.ini to get the BIOS blue back. }
  OverrideRGB[1,0]:=0; OverrideRGB[1,1]:=0; OverrideRGB[1,2]:=28;
  Overridden[1]:=true;
  AnyOverride:=true;

  s:=LocateFile(INIFileName);
  if s='' then
    s:=INIFileName;
  New(ini, Init(s));
  ini^.Read;
  for i:=0 to 15 do
    begin
      s:=ini^.GetEntry(DacSection,DacTag+IntToStr(i),'');
      if (s<>'') and ParseRGB(s,r,g,b) then
        begin
          OverrideRGB[i,0]:=r;
          OverrideRGB[i,1]:=g;
          OverrideRGB[i,2]:=b;
          Overridden[i]:=true;
          AnyOverride:=true;
        end;
    end;
  Dispose(ini,Done);

  ApplyIDEPalette;
end;

procedure ApplyIDEPalette;
var
  i : integer;
begin
  if not AnyOverride then
    exit;
  for i:=0 to 15 do
    if Overridden[i] then
      SetDac(i,OverrideRGB[i,0],OverrideRGB[i,1],OverrideRGB[i,2]);
end;

procedure RestoreDefaultPalette;
var
  i : integer;
begin
  if not AnyOverride then
    exit;
  for i:=0 to 15 do
    if Overridden[i] then
      SetDac(i,DefaultRGB[i,0],DefaultRGB[i,1],DefaultRGB[i,2]);
end;

end.
