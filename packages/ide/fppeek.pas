{
    This file is part of the Free Pascal Integrated Development Environment

    Peek-definition popup. Shows a small read-only window with a few
    lines of source around a target {file, line, col}, without
    moving the editor's cursor. Triggered by Shift+Tab in the source
    editor; the window owns the keyboard while open:

      Esc        close, no jump
      Enter      close + jump (i.e. promote the peek to a real
                 Ctrl+Enter style navigation)
      Up/Down    scroll the visible window line-by-line
      PgUp/PgDn  page

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
unit FPPeek;

{$H-}

interface

uses
  Objects;

function ShowPeek(const FileName: string;
                  TargetLine, TargetCol: sw_integer;
                  const Stale: boolean): boolean;
{ Pops up a modal peek window for FileName at the given 1-based
  line/col and returns true iff the user promoted it to a real jump
  (pressed Enter); returns false on Esc / dismissal. The caller is
  responsible for performing the jump (TryToOpenFile + nav-stack push)
  on a true return.
  If Stale is true the title is annotated to warn that the source on
  disk has drifted from the browser-info snapshot. }

implementation

uses
  Dos,
  Drivers, Views, App,
  FVConsts,
  WUtils,
  FPViews, FPNavStk;

const
  PeekContextLines = 12;       { lines to load on either side of target }
  PeekViewportLines = 12;      { rows of source visible at once }
  PeekWindowWidth   = 78;
  PeekMaxLines      = 2*PeekContextLines + 1;

type
  TPeekLineArr = array[0..PeekMaxLines-1] of PString;
  TPeekLineNoArr = array[0..PeekMaxLines-1] of sw_integer;

  PPeekWindow = ^TPeekWindow;
  TPeekWindow = object(TFPWindow)
    Lines     : TPeekLineArr;     { loaded source }
    LineNos   : TPeekLineNoArr;   { 1-based line numbers in source file }
    LineCount : sw_integer;       { populated entries in Lines[] }
    TopRow    : sw_integer;       { index into Lines[] at top of viewport }
    TargetIdx : sw_integer;       { index into Lines[] of the target line }
    TargetFile: PString;
    TargetLine: sw_integer;
    TargetCol : sw_integer;
    constructor Init(const AFileName: string;
                     ATargetLine, ATargetCol: sw_integer;
                     AStale: boolean);
    procedure   LoadContent(const AFileName: string; ATargetLine: sw_integer);
    procedure   Draw; virtual;
    procedure   HandleEvent(var Event: TEvent); virtual;
    procedure   Scroll(Delta: sw_integer);
    destructor  Done; virtual;
  end;

{----------------------------------------------------------------}

procedure CenteredBounds(var R: TRect; W, H: sw_integer);
var
  ScreenW, ScreenH: sw_integer;
begin
  ScreenW:=Application^.Size.X;
  ScreenH:=Application^.Size.Y;
  if W>ScreenW-2 then W:=ScreenW-2;
  if H>ScreenH-2 then H:=ScreenH-2;
  R.A.X:=(ScreenW-W) div 2;
  R.A.Y:=(ScreenH-H) div 2;
  R.B.X:=R.A.X+W;
  R.B.Y:=R.A.Y+H;
end;

{----------------------------------------------------------------}

constructor TPeekWindow.Init(const AFileName: string;
                             ATargetLine, ATargetCol: sw_integer;
                             AStale: boolean);
var
  R       : TRect;
  PeekTitle : string;
  WinH    : sw_integer;
  i       : sw_integer;
  ShortFn : string;
  P       : sw_integer;
begin
  WinH:=PeekViewportLines + 2;  { content + top/bottom borders }
  CenteredBounds(R, PeekWindowWidth, WinH);

  { Compose title: "filename:line [stale]" with directory stripped. }
  ShortFn:=AFileName;
  P:=Length(ShortFn);
  while (P>0) and not (ShortFn[P] in ['\','/',':']) do Dec(P);
  if P>0 then ShortFn:=Copy(ShortFn, P+1, Length(ShortFn)-P);
  PeekTitle:='Peek: '+ShortFn+':'+IntToStr(ATargetLine);
  if AStale then PeekTitle:=PeekTitle+' (stale)';

  inherited Init(R, PeekTitle, wnNoNumber);
  AutoNumber:=false;
  Flags:=Flags and not (wfGrow or wfZoom);
  Options:=Options or ofSelectable;
  GrowMode:=0;
  Palette:=wpCyanWindow;

  for i:=0 to PeekMaxLines-1 do
    begin
      Lines[i]:=nil;
      LineNos[i]:=0;
    end;
  LineCount:=0;
  TopRow:=0;
  TargetIdx:=-1;
  TargetFile:=NewStr(AFileName);
  TargetLine:=ATargetLine;
  TargetCol:=ATargetCol;

  LoadContent(AFileName, ATargetLine);

  { Position viewport so target line sits roughly 1/3 down. }
  if TargetIdx>=0 then
    begin
      TopRow:=TargetIdx - (PeekViewportLines div 3);
      if TopRow<0 then TopRow:=0;
      if TopRow > LineCount - PeekViewportLines then
        TopRow:=LineCount - PeekViewportLines;
      if TopRow<0 then TopRow:=0;
    end;
end;

procedure TPeekWindow.LoadContent(const AFileName: string;
                                  ATargetLine: sw_integer);
var
  f         : text;
  curLine   : sw_integer;
  firstLine, lastLine: sw_integer;
  s         : string;
  idx       : sw_integer;
  resolved  : string;
begin
  firstLine:=ATargetLine - PeekContextLines;
  if firstLine<1 then firstLine:=1;
  lastLine:=ATargetLine + PeekContextLines;

  { Browser info often records bare basenames (e.g. uvgadriver.pas).
    Resolve through the IDE's -Fu/-Fi search path before opening. }
  resolved:=LocateSourceFile(AFileName, false);
  if resolved='' then resolved:=AFileName;
  if TargetFile<>nil then DisposeStr(TargetFile);
  TargetFile:=NewStr(resolved);

  Assign(f, resolved);
  {$I-} Reset(f); {$I+}
  if IOResult<>0 then
    begin
      Lines[0]:=NewStr('  (cannot open '+resolved+')');
      LineNos[0]:=0;
      LineCount:=1;
      exit;
    end;

  curLine:=0;
  idx:=0;
  while (not Eof(f)) and (idx<PeekMaxLines) do
    begin
      Inc(curLine);
      ReadLn(f, s);
      if (curLine>=firstLine) and (curLine<=lastLine) then
        begin
          { Replace tabs with two spaces for stable rendering. }
          while Pos(#9, s)>0 do s[Pos(#9,s)]:=' ';
          Lines[idx]:=NewStr(s);
          LineNos[idx]:=curLine;
          if curLine=ATargetLine then TargetIdx:=idx;
          Inc(idx);
        end;
      if curLine>lastLine then break;
    end;
  System.Close(f);
  LineCount:=idx;
end;

destructor TPeekWindow.Done;
var i: sw_integer;
begin
  for i:=0 to PeekMaxLines-1 do
    if Lines[i]<>nil then DisposeStr(Lines[i]);
  if TargetFile<>nil then DisposeStr(TargetFile);
  inherited Done;
end;

procedure TPeekWindow.Scroll(Delta: sw_integer);
var maxTop: sw_integer;
begin
  maxTop:=LineCount - PeekViewportLines;
  if maxTop<0 then maxTop:=0;
  TopRow:=TopRow+Delta;
  if TopRow<0 then TopRow:=0;
  if TopRow>maxTop then TopRow:=maxTop;
  DrawView;
end;

function PadLeft(const S: string; W: sw_integer): string;
var r: string;
begin
  r:=S;
  while Length(r)<W do r:=' '+r;
  PadLeft:=r;
end;

procedure TPeekWindow.Draw;
var
  B        : TDrawBuffer;
  i, j     : sw_integer;
  innerW   : sw_integer;
  innerH   : sw_integer;
  srcIdx   : sw_integer;
  rowAttr  : word;
  normAttr : word;
  hiAttr   : word;
  gutterAttr : word;
  gutter, content : string;
  wL, wR   : sw_integer;
begin
  inherited Draw;  { paints the frame + title via subview }

  innerW:=Size.X - 2;
  innerH:=Size.Y - 2;
  if (innerW<=0) or (innerH<=0) then exit;

  { Hardcoded text-mode attributes (low byte ignored, high byte = colour).
    $1F = high-intensity white on blue (normal text).
    $1E = yellow on blue (highlighted target row).
    $17 = light grey on blue (gutter for line numbers). }
  normAttr   := $1F00;
  hiAttr     := $1E00;
  gutterAttr := $1700;

  for i:=0 to innerH-1 do
    begin
      srcIdx:=TopRow+i;
      MoveChar(B, ' ', Hi(normAttr), innerW);

      if (srcIdx>=0) and (srcIdx<LineCount) then
        begin
          if LineNos[srcIdx]>0 then
            gutter:=PadLeft(IntToStr(LineNos[srcIdx]),5)+' '
          else
            gutter:='      ';
          if Lines[srcIdx]<>nil then
            content:=Lines[srcIdx]^
          else
            content:='';

          wL:=Length(gutter);
          wR:=innerW - wL;
          if wR<0 then wR:=0;
          if Length(content)>wR then content:=Copy(content,1,wR);

          MoveStr(B[0], gutter, Hi(gutterAttr));
          if (srcIdx=TargetIdx) and (TargetIdx>=0) then
            rowAttr:=hiAttr
          else
            rowAttr:=normAttr;
          MoveStr(B[wL], content, Hi(rowAttr));

          if (srcIdx=TargetIdx) and (Length(content)<wR) then
            for j:=wL+Length(content) to innerW-1 do
              B[j]:=hiAttr or ord(' ');
        end;

      WriteLine(1, 1+i, innerW, 1, B);
    end;
end;

procedure TPeekWindow.HandleEvent(var Event: TEvent);
begin
  case Event.What of
    evKeyDown :
      begin
        case Event.KeyCode of
          kbEsc :
            begin
              ClearEvent(Event);
              EndModal(cmCancel);
            end;
          kbEnter :
            begin
              ClearEvent(Event);
              EndModal(cmOK);
            end;
          kbUp     : begin Scroll(-1); ClearEvent(Event); end;
          kbDown   : begin Scroll( 1); ClearEvent(Event); end;
          kbPgUp   : begin Scroll(-PeekViewportLines); ClearEvent(Event); end;
          kbPgDn   : begin Scroll( PeekViewportLines); ClearEvent(Event); end;
          kbHome,
          kbCtrlPgUp : begin TopRow:=0; DrawView; ClearEvent(Event); end;
          kbEnd,
          kbCtrlPgDn :
            begin
              TopRow:=LineCount-PeekViewportLines;
              if TopRow<0 then TopRow:=0;
              DrawView;
              ClearEvent(Event);
            end;
        end;
      end;
  end;
  inherited HandleEvent(Event);
end;

{----------------------------------------------------------------}

function ShowPeek(const FileName: string;
                  TargetLine, TargetCol: sw_integer;
                  const Stale: boolean): boolean;
var
  W      : PPeekWindow;
  result_: word;
begin
  ShowPeek:=false;
  if FileName='' then exit;
  if TargetLine<=0 then TargetLine:=1;
  if TargetCol<=0  then TargetCol:=1;
  New(W, Init(FileName, TargetLine, TargetCol, Stale));
  if W=nil then exit;
  result_:=Application^.ExecView(W);
  Dispose(W, Done);
  ShowPeek:=result_=cmOK;
end;

end.
