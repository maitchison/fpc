{
    S3-specific text-mode probing for the FP IDE.
    Copyright (c) 2026 — local patch, not upstream.

    Purpose: on real S3 Virge / Trio hardware the VBE BIOS typically does
    not list 132-column text modes in its 4F00h mode list, so
    InitVESAScreenModes only finds 80x25 / 80x50. The wide text modes
    exist but have to be set via the legacy INT 10h AX=00xxh path using
    S3-specific mode bytes.

    Strategy:
      1. Detect S3 by the VBE OEM string (fast, no hardware poke).
      2. For each candidate mode byte, call INT 10h AX=00xxh and read back
         the current mode. If the readback matches, register it as an S3
         entry in the vesa.pas mode list.
      3. Restore the original mode.

    The registrar (RegisterS3VideoMode) dedups by (cols, rows, color) so a
    mode already exposed via VBE is not re-added.
}
unit S3Modes;

{$H-}

interface

function S3DetectAndProbe : word;

const
  DisableS3  : boolean = false;
  S3Detected : boolean = false;

implementation

uses
  Dos,
  VESA;

type
  S3ModeCandidate = record
    ModeByte : byte;
    Cols     : word;
    Rows     : word;
  end;

const
  { Conservative subset. Mode bytes documented across S3 Trio / Virge /
    ViRGE families. Some chips support a superset; we only keep the ones
    that the probe confirms.

    $22  80x30
    $23  132x25   (most S3 BIOSes)
    $24  132x43
    $26  132x50   (Trio64 / Virge)
    $54  132x43   (alternate on some BIOSes)
    $55  132x25   (alternate on some BIOSes) }
  S3Candidates : array[0..5] of S3ModeCandidate = (
    (ModeByte: $22; Cols: 80;  Rows: 30),
    (ModeByte: $23; Cols: 132; Rows: 25),
    (ModeByte: $24; Cols: 132; Rows: 43),
    (ModeByte: $26; Cols: 132; Rows: 50),
    (ModeByte: $54; Cols: 132; Rows: 43),
    (ModeByte: $55; Cols: 132; Rows: 25)
  );

function UpCaseStr(const S: string): string;
var i: integer;
begin
  UpCaseStr:=S;
  for i:=1 to Length(UpCaseStr) do
    if (UpCaseStr[i]>='a') and (UpCaseStr[i]<='z') then
      UpCaseStr[i]:=Chr(Ord(UpCaseStr[i])-32);
end;

function ContainsSubstr(const Haystack, Needle: string): boolean;
var i, n, h: integer;
    j: integer;
    match: boolean;
begin
  h:=Length(Haystack); n:=Length(Needle);
  ContainsSubstr:=false;
  if (n=0) or (n>h) then exit;
  for i:=1 to h-n+1 do
    begin
      match:=true;
      for j:=1 to n do
        if Haystack[i+j-1]<>Needle[j] then
          begin match:=false; break; end;
      if match then
        begin ContainsSubstr:=true; exit; end;
    end;
end;

function DetectS3: boolean;
var oem : string;
begin
  DetectS3:=false;
  oem:=UpCaseStr(VESAGetOemString);
  if ContainsSubstr(oem,'S3 ') or
     ContainsSubstr(oem,'TRIO') or
     ContainsSubstr(oem,'VIRGE') or
     ContainsSubstr(oem,'VISION') or
     ContainsSubstr(oem,'86C') then
    DetectS3:=true;
end;

function GetCurrentMode: byte;
var r: registers;
begin
  r.ah:=$0f;
  dos.intr($10,r);
  GetCurrentMode:=r.al and $7f;
end;

{ Try to set a legacy text mode via INT 10h AX=00xxh, then read back.
  Returns true iff the readback matches. }
function TryMode(ModeByte: byte): boolean;
var r: registers;
begin
  r.ah:=$00; r.al:=ModeByte;
  dos.intr($10,r);
  r.ah:=$0f;
  dos.intr($10,r);
  TryMode:=((r.al and $7f) = (ModeByte and $7f));
end;

procedure RestoreMode(ModeByte: byte);
var r: registers;
begin
  r.ah:=$00; r.al:=ModeByte;
  dos.intr($10,r);
end;

function S3DetectAndProbe : word;
var
  registered : word;
  origMode   : byte;
  i          : integer;
begin
  registered:=0;
  S3DetectAndProbe:=0;
  if DisableS3 then exit;
  S3Detected:=DetectS3;
  if not S3Detected then exit;

  origMode:=GetCurrentMode;

  for i:=Low(S3Candidates) to High(S3Candidates) do
    begin
      if TryMode(S3Candidates[i].ModeByte) then
        begin
          if RegisterS3VideoMode(S3Candidates[i].ModeByte,
                                 S3Candidates[i].Cols,
                                 S3Candidates[i].Rows,
                                 true) then
            Inc(registered);
        end;
    end;

  { Restore the mode that was active before we started probing. The probe
    may have left the card in whatever candidate we last set. }
  RestoreMode(origMode);

  S3DetectAndProbe:=registered;
end;

end.
