{
    This file is part of the Free Pascal Integrated Development Environment

    Heap status: a true picture of the IDE's DPMI footprint, plus a
    diagnostic dump for analysing why F9-Run sees so little memory.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
unit FPHeap;

{$i globdir.inc}

interface

uses Objects, Drivers, Views, Dialogs, App;

type
  THeapInfo = record
    FPC: TFPCHeapStatus;
    HasDpmi: boolean;
    DpmiLargestK: longint;     { available_memory: largest free chunk DPMI will hand out, KB }
    DpmiPhysFreeK: longint;    { available_physical_pages * 4 KB }
    DpmiPhysTotalK: longint;   { total_physical_pages   * 4 KB }
    DpmiVerMajor: byte;
    DpmiVerMinor: byte;
    DpmiVerOk: boolean;
    HasMemInfoRaw: boolean;    { whether RawMemInfo is populated (go32v2 only) }
{$ifdef go32v2}
    RawMemInfo: record
      available_memory,
      available_pages,
      available_lockable_pages,
      linear_space,
      unlocked_pages,
      available_physical_pages,
      total_physical_pages,
      free_linear_space,
      max_pages_in_paging_file: longint;
    end;
{$endif}
  end;

procedure GatherHeapInfo(var info: THeapInfo);

{ Format the bottom-right widget contents for the detailed mode.
  Caller decides width via WidthCols; we trim to fit. }
function FormatHeapShort(const info: THeapInfo; widthCols: longint): string;

procedure ShowHeapStatusDialog;
function  DumpHeapDiagnostics(const path: string): boolean;

implementation

uses
{$ifdef go32v2}
  Go32,
{$endif}
  Dos, Strings, FVConsts, Version, WViews, FPConst;

type
  PHeapStatusDialog = ^THeapStatusDialog;
  THeapStatusDialog = object(TDialog)
    constructor Init;
    procedure   HandleEvent(var Event: TEvent); virtual;
    procedure   Refresh;
  private
    Lines: array[1..14] of PStaticText;
  end;

{ ------------------------------ helpers ----------------------------------- }

function CommaKB(kb: longint): string;
{ Group thousands with ',' for readability. }
var
  raw, S: string;
  i, n: longint;
begin
  Str(kb, raw);
  S := '';
  n := 0;
  for i := length(raw) downto 1 do
  begin
    if raw[i] = '-' then
    begin
      S := raw[i] + S;
      continue;
    end;
    if (n > 0) and (n mod 3 = 0) then
      S := ',' + S;
    S := raw[i] + S;
    inc(n);
  end;
  CommaKB := S;
end;

function PadLeft(const S: string; w: longint): string;
var
  pad: string;
  i: longint;
begin
  pad := '';
  for i := 1 to w - length(S) do
    pad := pad + ' ';
  PadLeft := pad + S;
end;

function MBStr(kb: longint): string;
{ Compact size: <1 MB → "Nk", >=1 MB → "Nm" using integer MB. }
var
  S: string;
begin
  if kb < 0 then
  begin
    MBStr := '?';
    Exit;
  end;
  if kb < 1024 then
  begin
    Str(kb, S);
    MBStr := S + 'k';
  end
  else
  begin
    Str(kb shr 10, S);
    MBStr := S + 'm';
  end;
end;

{ ----------------------------- gather ------------------------------------- }

procedure GatherHeapInfo(var info: THeapInfo);
{$ifdef go32v2}
var
  mi: tmeminfo;
  vi: tdpmiversioninfo;
{$endif}
begin
  FillChar(info, sizeof(info), 0);
  info.FPC := GetFPCHeapStatus;
  info.DpmiLargestK := -1;
{$ifdef go32v2}
  if get_meminfo(mi) then
  begin
    info.HasDpmi := true;
    info.HasMemInfoRaw := true;
    info.RawMemInfo.available_memory          := mi.available_memory;
    info.RawMemInfo.available_pages           := mi.available_pages;
    info.RawMemInfo.available_lockable_pages  := mi.available_lockable_pages;
    info.RawMemInfo.linear_space              := mi.linear_space;
    info.RawMemInfo.unlocked_pages            := mi.unlocked_pages;
    info.RawMemInfo.available_physical_pages  := mi.available_physical_pages;
    info.RawMemInfo.total_physical_pages      := mi.total_physical_pages;
    info.RawMemInfo.free_linear_space         := mi.free_linear_space;
    info.RawMemInfo.max_pages_in_paging_file  := mi.max_pages_in_paging_file;
    if mi.available_memory >= 0 then
      info.DpmiLargestK := mi.available_memory shr 10
    else
      info.DpmiLargestK := -1;
    info.DpmiPhysFreeK  := mi.available_physical_pages * 4;
    info.DpmiPhysTotalK := mi.total_physical_pages * 4;
  end;
  if get_dpmi_version(vi) then
  begin
    info.DpmiVerOk := true;
    info.DpmiVerMajor := vi.major;
    info.DpmiVerMinor := vi.minor;
  end;
{$endif}
end;

function FormatHeapShort(const info: THeapInfo; widthCols: longint): string;
{ Compact "I 24m D 20m" form for the bottom-right widget.
  Falls back to "I N" or just "Nm" if the column budget is tight. }
var
  ide, dpmi, S: string;
begin
  ide := MBStr(info.FPC.CurrHeapSize shr 10);
  if info.HasDpmi and (info.DpmiLargestK >= 0) then
    dpmi := MBStr(info.DpmiLargestK)
  else
    dpmi := '?';
  S := 'I ' + ide + ' D ' + dpmi;
  if length(S) <= widthCols then
  begin
    FormatHeapShort := S;
    Exit;
  end;
  S := ide + '/' + dpmi;
  if length(S) <= widthCols then
  begin
    FormatHeapShort := S;
    Exit;
  end;
  FormatHeapShort := ide;
end;

{ ----------------------------- dialog ------------------------------------- }

constructor THeapStatusDialog.Init;
var
  R, R2: TRect;
  i: longint;
begin
  R.Assign(0, 0, 56, 17);
  inherited Init(R, 'Heap status');
  Options := Options or ofCentered;
  EventMask := EventMask or evIdle;
  HelpCtx := hcHeapStatus;
  GetExtent(R); R.Grow(-2, -1);

  R2.Copy(R); R2.B.Y := R2.A.Y + 1;
  for i := 1 to 14 do
  begin
    New(Lines[i], Init(R2, ''));
    Insert(Lines[i]);
    R2.Move(0, 1);
  end;

  InsertOK(@Self);
  Refresh;
end;

procedure THeapStatusDialog.Refresh;
var
  info: THeapInfo;
  i: longint;
  txt: array[1..14] of string;
  idleK: longint;
  S: string;

  procedure SetLine(idx: longint; const NewText: string);
  begin
    if (idx >= 1) and (idx <= 14) and (Lines[idx] <> nil) then
    begin
      DisposeStr(Lines[idx]^.Text);
      Lines[idx]^.Text := NewStr(NewText);
      Lines[idx]^.DrawView;
    end;
  end;

begin
  GatherHeapInfo(info);
  for i := 1 to 14 do txt[i] := '';
  idleK := (info.FPC.CurrHeapSize - info.FPC.CurrHeapUsed) shr 10;

  txt[1]  := 'IDE memory:';
  txt[2]  := '  Currently in use      : ' + PadLeft(CommaKB(info.FPC.CurrHeapUsed shr 10), 10) + ' KB';
  txt[3]  := '  Manager-allocated     : ' + PadLeft(CommaKB(info.FPC.CurrHeapSize shr 10), 10) + ' KB  (real DPMI cost)';
  txt[4]  := '  Peak ever             : ' + PadLeft(CommaKB(info.FPC.MaxHeapSize  shr 10), 10) + ' KB';
  txt[5]  := '  Held but idle         : ' + PadLeft(CommaKB(idleK),                          10) + ' KB';
  txt[6]  := '';
  txt[7]  := 'DPMI host:';
  if info.HasDpmi then
  begin
    txt[8]  := '  Total physical (host) : ' + PadLeft(CommaKB(info.DpmiPhysTotalK), 10) + ' KB';
    txt[9]  := '  Physical free         : ' + PadLeft(CommaKB(info.DpmiPhysFreeK),  10) + ' KB';
    txt[10] := '  Largest free chunk    : ' + PadLeft(CommaKB(info.DpmiLargestK),   10) + ' KB  (F9 ceiling)';
  end
  else
  begin
    txt[8]  := '  (DPMI memory info not available on this target)';
    txt[9]  := '';
    txt[10] := '';
  end;
  if info.DpmiVerOk then
  begin
    Str(info.DpmiVerMajor, S);
    txt[11] := '  DPMI version          : ' + S + '.';
    if info.DpmiVerMinor < 10 then txt[11] := txt[11] + '0';
    Str(info.DpmiVerMinor, S);
    txt[11] := txt[11] + S;
  end;
  txt[13] := '';
  txt[14] := '"Manager-allocated" never shrinks on go32v2 (no SysOSFree).';

  for i := 1 to 14 do
    SetLine(i, txt[i]);
end;

procedure THeapStatusDialog.HandleEvent(var Event: TEvent);
begin
  if Event.What = evIdle then
    Refresh;
  inherited HandleEvent(Event);
end;

procedure ShowHeapStatusDialog;
begin
  Application^.ExecuteDialog(New(PHeapStatusDialog, Init), nil);
end;

{ ----------------------------- dump --------------------------------------- }

function DumpHeapDiagnostics(const path: string): boolean;
var
  f: text;
  info: THeapInfo;
  yyyy, mm, dd, wday: word;
  hh, nn, ss, hh100: word;

  procedure WriteHeader;
  begin
    writeln(f, '------------------------------------------------------------');
    writeln(f, 'FPC IDE heap diagnostics');
    GetDate(yyyy, mm, dd, wday);
    GetTime(hh, nn, ss, hh100);
    writeln(f, 'Timestamp: ', yyyy, '-', mm:0, '-', dd:0, ' ',
                              hh:0, ':', nn:0, ':', ss:0);
    writeln(f, 'IDE     : ', VersionStr);
    writeln(f, 'Compiler: ', Full_Version_String);
    writeln(f, '------------------------------------------------------------');
    writeln(f);
  end;

begin
  DumpHeapDiagnostics := false;
  GatherHeapInfo(info);

  Assign(f, path);
{$I-}
  Rewrite(f);
{$I+}
  if IOResult <> 0 then
    Exit;

  WriteHeader;

  writeln(f, 'IDE memory (FPC heap manager):');
  writeln(f, '  CurrHeapUsed  = ', PadLeft(CommaKB(info.FPC.CurrHeapUsed shr 10), 10), ' KB');
  writeln(f, '  CurrHeapSize  = ', PadLeft(CommaKB(info.FPC.CurrHeapSize shr 10), 10), ' KB  (real DPMI cost)');
  writeln(f, '  MaxHeapSize   = ', PadLeft(CommaKB(info.FPC.MaxHeapSize  shr 10), 10), ' KB');
  writeln(f, '  MaxHeapUsed   = ', PadLeft(CommaKB(info.FPC.MaxHeapUsed  shr 10), 10), ' KB');
  writeln(f, '  Held-but-idle = ', PadLeft(CommaKB((info.FPC.CurrHeapSize - info.FPC.CurrHeapUsed) shr 10), 10), ' KB');
  writeln(f);

  writeln(f, 'DPMI host:');
{$ifdef go32v2}
  if info.HasMemInfoRaw then
    with info.RawMemInfo do
    begin
      writeln(f, '  available_memory          = ', PadLeft(CommaKB(available_memory shr 10), 10), ' KB  (largest free block)');
      writeln(f, '  available_pages           = ', available_pages, '  (max unlocked alloc, in pages)');
      writeln(f, '  available_lockable_pages  = ', available_lockable_pages);
      writeln(f, '  linear_space (pages)      = ', linear_space);
      writeln(f, '  unlocked_pages            = ', unlocked_pages);
      writeln(f, '  available_physical_pages  = ', available_physical_pages, '  -> ', PadLeft(CommaKB(available_physical_pages * 4), 10), ' KB');
      writeln(f, '  total_physical_pages      = ', total_physical_pages,     '  -> ', PadLeft(CommaKB(total_physical_pages     * 4), 10), ' KB');
      writeln(f, '  free_linear_space         = ', free_linear_space);
      writeln(f, '  max_pages_in_paging_file  = ', max_pages_in_paging_file);
    end
  else
    writeln(f, '  get_meminfo failed -- DPMI host did not return memory info.');
  if info.DpmiVerOk then
    writeln(f, '  DPMI version              = ', info.DpmiVerMajor, '.', info.DpmiVerMinor:0,
              '   (0.90 = Windows 9x DPMI; 1.00 = cwsdpmi)');
{$else}
  writeln(f, '  (this build is not go32v2; DPMI numbers not applicable)');
{$endif}
  writeln(f);

  writeln(f, 'Interpretation:');
  writeln(f, '  * CurrHeapSize is the IDE process''s monotonic DPMI');
  writeln(f, '    high-water mark. SysOSFree is a no-op on go32v2, so this');
  writeln(f, '    number only ever grows -- it does not drop after a compile.');
  writeln(f, '  * available_memory (DPMI "largest free block") is the ceiling');
  writeln(f, '    on any further growth -- both for the IDE itself and, more');
  writeln(f, '    importantly, for child programs spawned via F9 Run.');
  writeln(f, '  * If Held-but-idle is large, the heap manager has substantial');
  writeln(f, '    free space internally but cannot release it back to DPMI.');

  Close(f);
  DumpHeapDiagnostics := true;
end;

end.
