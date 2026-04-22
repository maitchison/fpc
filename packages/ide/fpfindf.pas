{
    This file is part of the Free Pascal Integrated Development Environment

    Find in Files -- native in-process global search.
    Triggered from Search | Find in Files... (Ctrl+Shift+F).
    Results are pushed into the standard Messages window so Enter jumps
    to source via TMessageListBox.GotoSource.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
{$I globdir.inc}

unit FPFindF;

interface

const
  fifCaseSensitive     = $0001;
  fifWholeWord         = $0002;
  fifRecurse           = $0004;
  fifIncludeSourceDirs = $0008;

  FindInFilesStrSize   = 79;
  FindInFilesMaskSize  = 127;

  FindInFilesSearchId  = 110;
  FindInFilesIncludeId = 111;
  FindInFilesExcludeId = 112;

type
  TFindInFilesRec = record
    SearchStr  : String[FindInFilesStrSize];
    IncludeMask: String[FindInFilesMaskSize];
    ExcludeMask: String[FindInFilesMaskSize];
    Flags      : word;
  end;

const
  FindInFilesRec : TFindInFilesRec = (
    SearchStr  : '';
    IncludeMask: '*.pas;*.inc';
    ExcludeMask: '';
    Flags      : fifRecurse;
  );

function ExecuteFindInFilesDialog: boolean;
procedure RunFindInFilesSearch;

implementation

uses
  Dos, Objects, Drivers, Views, Dialogs, App, Menus, HistList,
  WUtils, WConsts,
  FPConst, FPVars, FPUtils, FPTools;

const
  MaxHits      = 500;
  MaxFileBytes = 1024 * 1024;

  ExtOrder : array[0..4] of string[4] =
    ('.PAS', '.INC', '.PP', '.DPR', '.LPR');

type
  TFileBuf = array[0..$7fffffff-1] of byte;
  PFileBuf = ^TFileBuf;

var
  HitCount  : longint;
  Cancelled : boolean;

{ ------------------------------------------------------------------ }
{  Helpers                                                           }
{ ------------------------------------------------------------------ }

function UpString(const S: string): string;
var i: integer; r: string;
begin
  r := S;
  for i := 1 to Length(r) do
    if r[i] in ['a'..'z'] then
      r[i] := Chr(Ord(r[i]) - 32);
  UpString := r;
end;

function IsWordChar(c: AnsiChar): boolean;
begin
  IsWordChar := c in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

{ DOS-style wildcard matching, case-insensitive. '*' matches any run;
  '?' matches exactly one char. }
function MatchWild(const Pattern, Name: string): boolean;
var
  pi, ni, sp, sn, pl, nl: integer;
begin
  pl := Length(Pattern); nl := Length(Name);
  pi := 1; ni := 1; sp := 0; sn := 0;
  while ni <= nl do
  begin
    if (pi <= pl) and (Pattern[pi] = '*') then
    begin
      sp := pi;
      sn := ni;
      Inc(pi);
    end
    else if (pi <= pl) and
            ((Pattern[pi] = '?') or
             (UpCase(Pattern[pi]) = UpCase(Name[ni]))) then
    begin
      Inc(pi); Inc(ni);
    end
    else if sp > 0 then
    begin
      pi := sp + 1;
      Inc(sn);
      ni := sn;
    end
    else
    begin
      MatchWild := false;
      exit;
    end;
  end;
  while (pi <= pl) and (Pattern[pi] = '*') do Inc(pi);
  MatchWild := pi > pl;
end;

{ True if Name matches any mask in the ';'-separated list. Empty list
  never matches. }
function MatchAnyMask(const Name, MaskList: string): boolean;
var
  i, j, lm: integer;
  mask: string;
begin
  MatchAnyMask := false;
  lm := Length(MaskList);
  if lm = 0 then exit;
  i := 1;
  while i <= lm do
  begin
    j := i;
    while (j <= lm) and (MaskList[j] <> ';') do Inc(j);
    mask := Copy(MaskList, i, j - i);
    while (Length(mask) > 0) and (mask[1] = ' ') do Delete(mask, 1, 1);
    while (Length(mask) > 0) and (mask[Length(mask)] = ' ') do
      Delete(mask, Length(mask), 1);
    if (mask <> '') and MatchWild(mask, Name) then
    begin
      MatchAnyMask := true;
      exit;
    end;
    i := j + 1;
  end;
end;

{ Extension priority (lower = visited first). .pas, .inc, .pp, .dpr,
  .lpr, then anything else. }
function ExtPriority(const FileName: string): integer;
var e: string; i: integer;
begin
  e := UpString(ExtOf(FileName));
  for i := Low(ExtOrder) to High(ExtOrder) do
    if e = ExtOrder[i] then
    begin
      ExtPriority := i;
      exit;
    end;
  ExtPriority := High(ExtOrder) + 1;
end;

{ Non-blocking Esc check. Sets Cancelled if user pressed Esc. }
procedure PumpCancel;
var E: TEvent;
begin
  if Cancelled then exit;
  Drivers.GetKeyEvent(E);
  if (E.What = evKeyDown) and (E.KeyCode = kbEsc) then
    Cancelled := true;
end;

{ ------------------------------------------------------------------ }
{  File scanning                                                      }
{ ------------------------------------------------------------------ }

procedure ScanFile(const FullPath: string);
var
  f        : file;
  fsize    : longint;
  bytesRead: longint;
  buf      : PFileBuf;
  pat, patUp : string;
  caseSens : boolean;
  wholeWrd : boolean;
  row      : longint;
  lineStart, lineEnd, i : longint;
  lineLen  : longint;
  hitpos   : integer;
  patLen   : integer;
  lineBuf  : string;
  searchBuf: string;
  displayBuf: string;
  lok, rok : boolean;
begin
  if Cancelled or (HitCount >= MaxHits) then exit;

  {$I-}
  Assign(f, FullPath);
  Reset(f, 1);
  if IOResult <> 0 then exit;
  fsize := FileSize(f);
  if (fsize <= 0) or (fsize > MaxFileBytes) then
  begin
    Close(f); if IOResult <> 0 then ;
    exit;
  end;
  GetMem(buf, fsize);
  BlockRead(f, buf^, fsize, bytesRead);
  Close(f); if IOResult <> 0 then ;
  {$I+}

  caseSens := (FindInFilesRec.Flags and fifCaseSensitive) <> 0;
  wholeWrd := (FindInFilesRec.Flags and fifWholeWord) <> 0;
  pat      := FindInFilesRec.SearchStr;
  patUp    := UpString(pat);
  patLen   := Length(pat);
  if patLen = 0 then
  begin
    FreeMem(buf, fsize);
    exit;
  end;

  row       := 1;
  lineStart := 0;
  i         := 0;

  while (i < bytesRead) and (not Cancelled) and (HitCount < MaxHits) do
  begin
    lineEnd := i;
    while (lineEnd < bytesRead) and (buf^[lineEnd] <> $0A) do
      Inc(lineEnd);

    lineLen := lineEnd - lineStart;
    if (lineLen > 0) and (buf^[lineStart + lineLen - 1] = $0D) then
      Dec(lineLen);

    if lineLen >= patLen then
    begin
      { Copy the line to a ShortString (cap at 255). }
      if lineLen > 255 then
        SetLength(lineBuf, 255)
      else
        SetLength(lineBuf, lineLen);
      if Length(lineBuf) > 0 then
        Move(buf^[lineStart], lineBuf[1], Length(lineBuf));

      if caseSens then
        hitpos := Pos(pat, lineBuf)
      else
      begin
        searchBuf := UpString(lineBuf);
        hitpos := Pos(patUp, searchBuf);
      end;

      if (hitpos > 0) and wholeWrd then
      begin
        lok := hitpos = 1;
        if not lok then
          lok := not IsWordChar(lineBuf[hitpos - 1]);
        rok := hitpos + patLen - 1 >= Length(lineBuf);
        if not rok then
          rok := not IsWordChar(lineBuf[hitpos + patLen]);
        if not (lok and rok) then
          hitpos := 0;
      end;

      if hitpos > 0 then
      begin
        displayBuf := lineBuf;
        while (Length(displayBuf) > 0) and
              ((displayBuf[1] = ' ') or (displayBuf[1] = #9)) do
          Delete(displayBuf, 1, 1);
        if Length(displayBuf) > 200 then
          SetLength(displayBuf, 200);

        AddToolMessage(FullPath, displayBuf, row, hitpos);
        Inc(HitCount);
      end;
    end;

    i         := lineEnd + 1;
    lineStart := i;
    Inc(row);

    if (row and 255) = 0 then
      PumpCancel;
  end;

  FreeMem(buf, fsize);
end;

{ ------------------------------------------------------------------ }
{  Directory walk                                                    }
{ ------------------------------------------------------------------ }

procedure ScanDirFilesAtPriority(const Dir: string; TargetPri: integer);
var sr: SearchRec;
begin
  FindFirst(Dir + '*.*', Archive + ReadOnly, sr);
  while DosError = 0 do
  begin
    if ((sr.Attr and Directory) = 0) and
       (ExtPriority(sr.Name) = TargetPri) and
       MatchAnyMask(sr.Name, FindInFilesRec.IncludeMask) and
       not MatchAnyMask(sr.Name, FindInFilesRec.ExcludeMask) then
      ScanFile(Dir + sr.Name);
    if Cancelled or (HitCount >= MaxHits) then break;
    FindNext(sr);
  end;
  FindClose(sr);
end;

procedure ScanDir(const Dir: string);
var sr: SearchRec;
    pri: integer;
    subDir: string;
begin
  if Cancelled or (HitCount >= MaxHits) then exit;
  PumpCancel;
  if Cancelled then exit;

  for pri := Low(ExtOrder) to High(ExtOrder) + 1 do
  begin
    if Cancelled or (HitCount >= MaxHits) then exit;
    ScanDirFilesAtPriority(Dir, pri);
  end;

  if (FindInFilesRec.Flags and fifRecurse) = 0 then exit;
  if Cancelled or (HitCount >= MaxHits) then exit;

  FindFirst(Dir + '*.*', Directory + Archive + ReadOnly, sr);
  while (DosError = 0) and (not Cancelled) and (HitCount < MaxHits) do
  begin
    if ((sr.Attr and Directory) <> 0) and
       (sr.Name <> '.') and (sr.Name <> '..') and
       not MatchAnyMask(sr.Name, FindInFilesRec.ExcludeMask) then
    begin
      subDir := Dir + sr.Name + DirSep;
      ScanDir(subDir);
    end;
    FindNext(sr);
  end;
  FindClose(sr);
end;

{ ------------------------------------------------------------------ }
{  Top-level search driver                                           }
{ ------------------------------------------------------------------ }

procedure RunFindInFilesSearch;
var
  root, cur  : string;
  sources, item : string;
  i, j, lm   : integer;
  rootUp     : string;
begin
  HitCount  := 0;
  Cancelled := false;

  if FindInFilesRec.SearchStr = '' then exit;

  if PrimaryFile <> '' then
    root := DirOf(FExpand(PrimaryFile))
  else
  begin
    GetDir(0, cur);
    if (cur <> '') and (cur[Length(cur)] <> DirSep) then
      cur := cur + DirSep;
    root := cur;
  end;

  AddToolMessage('', 'Find in Files: "' + FindInFilesRec.SearchStr +
    '" in ' + root, 0, 0);
  UpdateToolMessages;

  ScanDir(root);

  if ((FindInFilesRec.Flags and fifIncludeSourceDirs) <> 0) and
     (not Cancelled) and (HitCount < MaxHits) then
  begin
    rootUp := UpString(root);
    sources := SourceDirs;
    lm := Length(sources);
    i := 1;
    while (i <= lm) and (not Cancelled) and (HitCount < MaxHits) do
    begin
      j := i;
      while (j <= lm) and (sources[j] <> ';') do Inc(j);
      item := Copy(sources, i, j - i);
      while (Length(item) > 0) and (item[1] = ' ') do Delete(item, 1, 1);
      while (Length(item) > 0) and (item[Length(item)] = ' ') do
        Delete(item, Length(item), 1);
      if item <> '' then
      begin
        item := FExpand(item);
        if (Length(item) > 0) and (item[Length(item)] <> DirSep) then
          item := item + DirSep;
        if UpString(item) <> rootUp then
          ScanDir(item);
      end;
      i := j + 1;
    end;
  end;

  if Cancelled then
    AddToolMessage('', '(search cancelled)', 0, 0)
  else if HitCount >= MaxHits then
    AddToolMessage('', '(truncated at 500 hits - refine the search)', 0, 0)
  else if HitCount = 0 then
    AddToolMessage('', '(no matches)', 0, 0);
end;

{ ------------------------------------------------------------------ }
{  Dialog                                                            }
{ ------------------------------------------------------------------ }

function ExecuteFindInFilesDialog: boolean;
var
  R, R1, R2 : TRect;
  D         : PDialog;
  IL1, IL2, IL3 : PInputLine;
  CB        : PCheckBoxes;
  Ctrl      : PView;
  flagsW    : word;
  res       : word;
begin
  ExecuteFindInFilesDialog := false;

  R.Assign(0, 0, 62, 18);
  New(D, Init(R, 'Find in Files'));
  with D^ do
  begin
    Options := Options or ofCentered;
    GetExtent(R); R.Grow(-3, -2);

    { Search text }
    R1.Copy(R); R1.B.X := 18; R1.B.Y := R1.A.Y + 1;
    R2.Copy(R); R2.B.X := R2.B.X - 3; R2.A.X := 18; R2.B.Y := R2.A.Y + 1;
    New(IL1, Init(R2, FindInFilesStrSize));
    IL1^.Data^ := FindInFilesRec.SearchStr;
    Insert(IL1);
    Insert(New(PLabel, Init(R1, 'Search ~t~ext', IL1)));
    R1.Assign(R2.B.X, R2.A.Y, R2.B.X + 3, R2.B.Y);
    Ctrl := New(PHistory, Init(R1, IL1, FindInFilesSearchId));
    Insert(Ctrl);

    { Include mask }
    R1.Copy(R); R1.Move(0, 2); R1.B.X := 18; R1.B.Y := R1.A.Y + 1;
    R2.Copy(R); R2.Move(0, 2); R2.B.X := R2.B.X - 3; R2.A.X := 18;
    R2.B.Y := R2.A.Y + 1;
    New(IL2, Init(R2, FindInFilesMaskSize));
    IL2^.Data^ := FindInFilesRec.IncludeMask;
    Insert(IL2);
    Insert(New(PLabel, Init(R1, '~I~nclude mask', IL2)));
    R1.Assign(R2.B.X, R2.A.Y, R2.B.X + 3, R2.B.Y);
    Ctrl := New(PHistory, Init(R1, IL2, FindInFilesIncludeId));
    Insert(Ctrl);

    { Exclude mask }
    R1.Copy(R); R1.Move(0, 4); R1.B.X := 18; R1.B.Y := R1.A.Y + 1;
    R2.Copy(R); R2.Move(0, 4); R2.B.X := R2.B.X - 3; R2.A.X := 18;
    R2.B.Y := R2.A.Y + 1;
    New(IL3, Init(R2, FindInFilesMaskSize));
    IL3^.Data^ := FindInFilesRec.ExcludeMask;
    Insert(IL3);
    Insert(New(PLabel, Init(R1, 'E~x~clude mask', IL3)));
    R1.Assign(R2.B.X, R2.A.Y, R2.B.X + 3, R2.B.Y);
    Ctrl := New(PHistory, Init(R1, IL3, FindInFilesExcludeId));
    Insert(Ctrl);

    { Options checkboxes }
    R1.Copy(R); Inc(R1.A.Y, 6); R1.B.Y := R1.A.Y + 1;
    R2.Copy(R1); R2.Move(0, 1); R2.B.Y := R2.A.Y + 4;
    New(CB, Init(R2,
      NewSItem('~C~ase sensitive',
      NewSItem('~W~hole words only',
      NewSItem('~R~ecurse subdirectories',
      NewSItem('Include ~a~dditional folders (-Fu)',
      nil))))));
    Insert(CB);
    Insert(New(PLabel, Init(R1, 'Options', CB)));
    flagsW := FindInFilesRec.Flags;
    CB^.SetData(flagsW);

    { Buttons }
    GetExtent(R); R.Grow(-15, -1); R.A.Y := R.B.Y - 2; R.B.X := R.A.X + 10;
    Insert(New(PButton, Init(R, '~O~k', cmOK, bfDefault)));
    R.Move(14, 0); R.B.X := R.A.X + 10;
    Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));

    IL1^.Select;
  end;

  res := Application^.ExecView(D);
  if res = cmOK then
  begin
    FindInFilesRec.SearchStr   := IL1^.Data^;
    FindInFilesRec.IncludeMask := IL2^.Data^;
    FindInFilesRec.ExcludeMask := IL3^.Data^;
    CB^.GetData(flagsW);
    FindInFilesRec.Flags := flagsW;
    ExecuteFindInFilesDialog := FindInFilesRec.SearchStr <> '';
  end;
  Dispose(D, Done);
end;

end.
