{
    This file is part of the Free Pascal Integrated Development Environment

    Quick-open file dialog (Ctrl+U). Shows a filterable list of source
    files drawn from the project directory and every -Fu / -Fi search
    directory. The set of file extensions to include is controlled by
    the QuickOpenRec.IncludeMask field (a ';'-separated DOS wildcard
    list, e.g. '*.pas;*.inc;*.pp;*.ini'); the dialog exposes it as an
    editable input line. Matching against the typed query is prefix-
    based on the file stem, also matching the stem with a leading 'U'
    stripped (so 'graph' finds ugraph.pas while 'uber' still finds
    uber.pas).

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 **********************************************************************}

{ Included by fpide.pas. }

const
  QuickOpenDialogW = 70;
  QuickOpenDialogH = 21;
  QuickOpenMaxQuery = 63;
  QuickOpenIncludeId = 113;

type
  PQuickOpenItem = ^TQuickOpenItem;
  TQuickOpenItem = record
    FullPath    : PString;   { absolute, original case, for open }
    DisplayName : PString;   { basename.ext, original case }
    DisplayDir  : PString;   { parent dir, original case }
    KeyA        : PString;   { upper(stem) }
    KeyB        : PString;   { upper(stem), leading 'U' stripped if len>1 }
    Score       : byte;      { 0 = prefix of KeyA, 1 = prefix of KeyB }
    ExtPri      : byte;      { 0=.pas, 1=.pp, 2=.inc, 3=.dpr/.lpr, 4=other }
  end;

  PQuickOpenOwnedList = ^TQuickOpenOwnedList;
  TQuickOpenOwnedList = object(TCollection)
    procedure FreeItem(Item: Pointer); virtual;
  end;

  PQuickOpenFilterList = ^TQuickOpenFilterList;
  TQuickOpenFilterList = object(TCollection)
    procedure FreeItem(Item: Pointer); virtual;
  end;

  PQuickOpenDialog = ^TQuickOpenDialog;

  PQuickOpenInput = ^TQuickOpenInput;
  TQuickOpenInput = object(TInputLine)
    LastSeen : string;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PQuickOpenMaskInput = ^TQuickOpenMaskInput;
  TQuickOpenMaskInput = object(TInputLine)
    LastSeen : string;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PQuickOpenListBox = ^TQuickOpenListBox;
  TQuickOpenListBox = object(TListBox)
    function GetText(Item, MaxLen: Sw_Integer): string; virtual;
  end;

  TQuickOpenDialog = object(TCenterDialog)
    AllItems    : PQuickOpenOwnedList;
    WideItems   : PQuickOpenOwnedList;   { mask-ignoring corpus, lazy }
    WideScanned : boolean;
    Input       : PQuickOpenInput;
    MaskInput   : PQuickOpenMaskInput;
    ListBox     : PQuickOpenListBox;
    Counts      : PStaticText;
    TotalCount  : Sw_Integer;
    FallbackPath: string;                { set by Enter-as-literal-path fallback }
    constructor Init;
    destructor  Done; virtual;
    procedure   HandleEvent(var Event: TEvent); virtual;
    procedure   ScanCorpus;
    procedure   ScanWideCorpus;
    procedure   Refilter;
    function    ChosenPath: string;
    function    TryResolveLiteralPath(const Q: string; var FullOut: string): boolean;
  end;

{----------------------------------------------------------------}
{  Small helpers                                                 }
{----------------------------------------------------------------}

function QOUpper(const S: string): string;
var i: Sw_Integer; r: string;
begin
  r := S;
  for i := 1 to Length(r) do
    if r[i] in ['a'..'z'] then
      r[i] := Chr(Ord(r[i]) - 32);
  QOUpper := r;
end;

function QOHasPrefix(const Q, S: string): boolean;
var i, lq: Sw_Integer;
begin
  lq := Length(Q);
  QOHasPrefix := false;
  if lq = 0 then begin QOHasPrefix := true; exit; end;
  if Length(S) < lq then exit;
  for i := 1 to lq do
    if S[i] <> Q[i] then exit;
  QOHasPrefix := true;
end;

function QOStripExt(const Name: string): string;
var i: Sw_Integer;
begin
  for i := Length(Name) downto 1 do
  begin
    if Name[i] = '.' then
    begin
      QOStripExt := Copy(Name, 1, i - 1);
      exit;
    end;
    if (Name[i] = '\') or (Name[i] = '/') or (Name[i] = ':') then break;
  end;
  QOStripExt := Name;
end;

{ True if Name matches QuickOpenRec.IncludeMask. Uses MatchAnyMask
  from FPFindF for parity with the Find-in-Files dialog. An empty
  mask matches nothing (caller must seed it with a sensible default). }
function QOMatchesMask(const Name: string): boolean;
begin
  QOMatchesMask := MatchAnyMask(Name, QuickOpenRec.IncludeMask);
end;

{ Extension priority for sort tie-breaking. Lower = preferred. Pascal
  source wins over headers, then over project files, then over anything
  else (e.g. .ini, .cfg) -- so typing 'encode' lands encode.pas above
  encode.ini even when both directories scan in. }
function QOExtPriority(const Name: string): byte;
var up: string; len: Sw_Integer;
begin
  up := QOUpper(Name);
  len := Length(up);
  if (len >= 4) and (Copy(up, len - 3, 4) = '.PAS') then
    QOExtPriority := 0
  else if (len >= 3) and (Copy(up, len - 2, 3) = '.PP') then
    QOExtPriority := 1
  else if (len >= 4) and (Copy(up, len - 3, 4) = '.INC') then
    QOExtPriority := 2
  else if (len >= 4) and ((Copy(up, len - 3, 4) = '.DPR') or
                          (Copy(up, len - 3, 4) = '.LPR')) then
    QOExtPriority := 3
  else
    QOExtPriority := 4;
end;

function QOPadRight(const S: string; Width: Sw_Integer): string;
var r: string; i: Sw_Integer;
begin
  r := S;
  if Length(r) > Width then
    r := Copy(r, 1, Width)
  else
    for i := Length(r) + 1 to Width do r := r + ' ';
  QOPadRight := r;
end;

function QODirOnly(const FullPath: string): string;
var d: string;
begin
  d := DirOf(FullPath);
  QODirOnly := TrimEndSlash(d);
end;

function QOBaseName(const FullPath: string): string;
var i: Sw_Integer;
begin
  for i := Length(FullPath) downto 1 do
    if (FullPath[i] = '\') or (FullPath[i] = '/') or (FullPath[i] = ':') then
    begin
      QOBaseName := Copy(FullPath, i + 1, Length(FullPath) - i);
      exit;
    end;
  QOBaseName := FullPath;
end;

{----------------------------------------------------------------}
{  Collections                                                   }
{----------------------------------------------------------------}

procedure TQuickOpenOwnedList.FreeItem(Item: Pointer);
var p: PQuickOpenItem;
begin
  if Item = nil then exit;
  p := PQuickOpenItem(Item);
  if p^.FullPath    <> nil then DisposeStr(p^.FullPath);
  if p^.DisplayName <> nil then DisposeStr(p^.DisplayName);
  if p^.DisplayDir  <> nil then DisposeStr(p^.DisplayDir);
  if p^.KeyA        <> nil then DisposeStr(p^.KeyA);
  if p^.KeyB        <> nil then DisposeStr(p^.KeyB);
  Dispose(p);
end;

procedure TQuickOpenFilterList.FreeItem(Item: Pointer);
begin
  { items are owned by AllItems; do nothing here }
end;

{----------------------------------------------------------------}
{  Custom input line — arrow keys forward, live filter           }
{----------------------------------------------------------------}

procedure TQuickOpenInput.HandleEvent(var Event: TEvent);
var
  dlg : PQuickOpenDialog;
  lb  : PQuickOpenListBox;
  newF: Sw_Integer;
  step: Sw_Integer;
  handled: boolean;
begin
  dlg := PQuickOpenDialog(Owner);
  handled := false;
  if (Event.What = evKeyDown) and (dlg <> nil) and (dlg^.ListBox <> nil) then
  begin
    lb := dlg^.ListBox;
    case Event.KeyCode of
      kbDown:
        begin
          if lb^.Range > 0 then
          begin
            newF := lb^.Focused + 1;
            if newF >= lb^.Range then newF := lb^.Range - 1;
            lb^.FocusItem(newF);
          end;
          handled := true;
        end;
      kbUp:
        begin
          if lb^.Range > 0 then
          begin
            newF := lb^.Focused - 1;
            if newF < 0 then newF := 0;
            lb^.FocusItem(newF);
          end;
          handled := true;
        end;
      kbPgDn:
        begin
          if lb^.Range > 0 then
          begin
            step := lb^.Size.Y;
            if step < 1 then step := 1;
            newF := lb^.Focused + step;
            if newF >= lb^.Range then newF := lb^.Range - 1;
            lb^.FocusItem(newF);
          end;
          handled := true;
        end;
      kbPgUp:
        begin
          if lb^.Range > 0 then
          begin
            step := lb^.Size.Y;
            if step < 1 then step := 1;
            newF := lb^.Focused - step;
            if newF < 0 then newF := 0;
            lb^.FocusItem(newF);
          end;
          handled := true;
        end;
      kbCtrlHome:
        begin
          if lb^.Range > 0 then lb^.FocusItem(0);
          handled := true;
        end;
      kbCtrlEnd:
        begin
          if lb^.Range > 0 then lb^.FocusItem(lb^.Range - 1);
          handled := true;
        end;
    end;
    if handled then
    begin
      ClearEvent(Event);
      exit;
    end;
  end;
  inherited HandleEvent(Event);
  if (Data <> nil) and (dlg <> nil) then
    if Data^ <> LastSeen then
    begin
      LastSeen := Data^;
      dlg^.Refilter;
    end;
end;

{----------------------------------------------------------------}
{  Mask input line — re-scan corpus when mask changes            }
{----------------------------------------------------------------}

procedure TQuickOpenMaskInput.HandleEvent(var Event: TEvent);
var dlg: PQuickOpenDialog;
begin
  inherited HandleEvent(Event);
  dlg := PQuickOpenDialog(Owner);
  if (Data <> nil) and (dlg <> nil) then
    if Data^ <> LastSeen then
    begin
      LastSeen := Data^;
      QuickOpenRec.IncludeMask := Data^;
      dlg^.ScanCorpus;
      dlg^.Refilter;
    end;
end;

{----------------------------------------------------------------}
{  Custom listbox — two-column row                               }
{----------------------------------------------------------------}

function TQuickOpenListBox.GetText(Item, MaxLen: Sw_Integer): string;
var
  p  : PQuickOpenItem;
  left, right, row: string;
  leftW: Sw_Integer;
begin
  GetText := '';
  if (List = nil) or (Item < 0) or (Item >= List^.Count) then exit;
  p := PQuickOpenItem(List^.At(Item));
  if p = nil then exit;
  left := '';
  if p^.DisplayName <> nil then left := p^.DisplayName^;
  right := '';
  if p^.DisplayDir <> nil then right := p^.DisplayDir^;
  leftW := 22;
  if MaxLen < (leftW + 2) then
    row := left
  else
    row := QOPadRight(left, leftW) + ' ' + right;
  if Length(row) > MaxLen then row := Copy(row, 1, MaxLen);
  GetText := row;
end;

{----------------------------------------------------------------}
{  Dialog                                                        }
{----------------------------------------------------------------}

constructor TQuickOpenDialog.Init;
var
  R, RL, RI, RML, RMI, RMH, RS, RSB, RB : TRect;
  VSB : PScrollBar;
  Lbl : PLabel;
  Hist: PHistory;
begin
  R.Assign(0, 0, QuickOpenDialogW, QuickOpenDialogH);
  inherited Init(R, dialog_openbyname);
  HelpCtx := hcOpenByName;
  AllItems := nil;
  WideItems := nil;
  WideScanned := false;
  Input    := nil;
  MaskInput:= nil;
  ListBox  := nil;
  Counts   := nil;
  TotalCount := 0;
  FallbackPath := '';

  GetExtent(R);
  R.Grow(-2, -1);

  { File-filter input line at top. Leave a 3-column strip on the
    right unused so the layout aligns with the mask line below. }
  RL.Copy(R); RL.B.Y := RL.A.Y + 1; RL.B.X := RL.A.X + 7;
  RI.Copy(R); RI.B.Y := RI.A.Y + 1; RI.A.X := RL.B.X + 1;
  RI.B.X := RI.B.X - 3;
  New(Input, Init(RI, QuickOpenMaxQuery));
  Input^.LastSeen := '';
  Insert(Input);
  New(Lbl, Init(RL, label_openbyname_filter, Input));
  Insert(Lbl);

  { Mask input line, one row below — with a history dropdown so
    previous masks can be recalled (mirrors Find in Files). }
  RML.Copy(RL); RML.Move(0, 2); RML.B.X := RL.A.X + 7;
  RMI.Copy(RI); RMI.Move(0, 2);
  New(MaskInput, Init(RMI, QuickOpenMaskSize));
  MaskInput^.Data^ := QuickOpenRec.IncludeMask;
  MaskInput^.LastSeen := QuickOpenRec.IncludeMask;
  Insert(MaskInput);
  New(Lbl, Init(RML, label_openbyname_mask, MaskInput));
  Insert(Lbl);
  RMH.Assign(RMI.B.X, RMI.A.Y, RMI.B.X + 3, RMI.B.Y);
  New(Hist, Init(RMH, MaskInput, QuickOpenIncludeId));
  Insert(Hist);

  { Scrollbar + list fill the middle. List occupies R minus the
    right-hand 1-column strip used by the scrollbar. }
  RB.Copy(R); RB.A.Y := RB.B.Y - 1; RB.B.Y := RB.A.Y + 1;
  RS.Copy(R); RS.A.Y := RMI.B.Y + 1; RS.B.Y := RB.A.Y - 1;
  RSB.Copy(RS); RSB.A.X := RS.B.X - 1;
  Dec(RS.B.X);
  VSB := New(PScrollBar, Init(RSB));
  Insert(VSB);
  New(ListBox, Init(RS, 1, VSB));
  Insert(ListBox);

  { Status line at the bottom }
  New(Counts, Init(RB, ''));
  Insert(Counts);

  Input^.Select;
end;

destructor TQuickOpenDialog.Done;
begin
  inherited Done;
  if AllItems <> nil then
  begin
    Dispose(AllItems, Done);
    AllItems := nil;
  end;
  if WideItems <> nil then
  begin
    Dispose(WideItems, Done);
    WideItems := nil;
  end;
end;

procedure TQuickOpenDialog.HandleEvent(var Event: TEvent);
var
  q, resolved: string;
begin
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) then
  begin
    if (ListBox <> nil) and (ListBox^.Range > 0) then
    begin
      ClearEvent(Event);
      EndModal(cmOK);
      exit;
    end;
    { No match in the listbox. If the query looks like a filename
      (contains a '.'), try to resolve it directly so files filtered
      out by the IncludeMask -- e.g. play.log -- can still be opened. }
    if Input <> nil then
    begin
      if Input^.Data <> nil then q := Input^.Data^ else q := '';
      if (Pos('.', q) > 0) and TryResolveLiteralPath(q, resolved) then
      begin
        FallbackPath := resolved;
        ClearEvent(Event);
        EndModal(cmOK);
        exit;
      end;
    end;
    { Nothing to pick — swallow the Enter so TDialog doesn't
      broadcast cmDefault to something unrelated. }
    ClearEvent(Event);
    exit;
  end;
  inherited HandleEvent(Event);
end;

function QOAlreadySeen(Seen: PUnsortedStringCollection; const KeyUpper: string): boolean;
var i: Sw_Integer;
begin
  QOAlreadySeen := false;
  for i := 0 to Seen^.Count - 1 do
    if Seen^.At(i)^ = KeyUpper then
    begin
      QOAlreadySeen := true;
      exit;
    end;
end;

{ Scan a single directory for source files and append to AllItems.
  Directory must already be normalised (no trailing slash). Skips items
  whose absolute path is already in 'seen'. When MatchAll is true the
  IncludeMask is ignored — used to populate the wide corpus that backs
  Enter-as-literal-path lookup (e.g. play.log). }
procedure QOScanDir(const Dir: string; Items: PQuickOpenOwnedList;
                    Seen: PUnsortedStringCollection; MatchAll: boolean);
var
  sr       : SearchRec;
  rc       : integer;
  full, base, stem, stemUp, stemStripped: string;
  item     : PQuickOpenItem;
  normDir  : string;
  fullKey  : string;
begin
  if Dir = '' then exit;
  if not ExistsDir(Dir) then exit;
  normDir := TrimEndSlash(Dir);

  FindFirst(normDir + '\*.*', Archive + ReadOnly, sr);
  rc := DosError;
  while rc = 0 do
  begin
    if (sr.Attr and Directory) = 0 then
      if MatchAll or QOMatchesMask(sr.Name) then
      begin
        base := sr.Name;
        full := FExpand(normDir + '\' + base);
        fullKey := QOUpper(full);
        if not QOAlreadySeen(Seen, fullKey) then
        begin
          stem := QOStripExt(base);
          stemUp := QOUpper(stem);
          if (Length(stemUp) > 1) and (stemUp[1] = 'U') then
            stemStripped := Copy(stemUp, 2, Length(stemUp) - 1)
          else
            stemStripped := stemUp;

          New(item);
          item^.FullPath    := NewStr(full);
          item^.DisplayName := NewStr(base);
          item^.DisplayDir  := NewStr(normDir);
          item^.KeyA        := NewStr(stemUp);
          item^.KeyB        := NewStr(stemStripped);
          item^.Score       := 0;
          item^.ExtPri      := QOExtPriority(base);
          Items^.Insert(item);
          Seen^.InsertStr(fullKey);
        end;
      end;
    FindNext(sr);
    rc := DosError;
  end;
  FindClose(sr);
end;

{ Split a semicolon-separated path list and scan each directory. }
procedure QOScanList(const Paths: string; Items: PQuickOpenOwnedList;
                     Seen: PUnsortedStringCollection; MatchAll: boolean);
var
  i, j, lm: Sw_Integer;
  piece: string;
begin
  lm := Length(Paths);
  if lm = 0 then exit;
  i := 1;
  while i <= lm do
  begin
    j := i;
    while (j <= lm) and (Paths[j] <> ';') do Inc(j);
    piece := Copy(Paths, i, j - i);
    while (Length(piece) > 0) and (piece[1] = ' ') do Delete(piece, 1, 1);
    while (Length(piece) > 0) and (piece[Length(piece)] = ' ') do
      Delete(piece, Length(piece), 1);
    if piece <> '' then
      QOScanDir(FExpand(piece), Items, Seen, MatchAll);
    i := j + 1;
  end;
end;

procedure TQuickOpenDialog.ScanCorpus;
var
  seen    : PUnsortedStringCollection;
  projDir : string;
begin
  { Re-scans replace the existing corpus rather than appending to it,
    so a mask change immediately reflects the new extension set. }
  if AllItems <> nil then
    Dispose(AllItems, Done);
  New(AllItems, Init(64, 64));
  New(seen, Init(64, 64));

  { 1. Project / current directory }
  if PrimaryFile <> '' then
    projDir := DirOf(FExpand(PrimaryFile))
  else
    GetDir(0, projDir);
  QOScanDir(TrimEndSlash(projDir), AllItems, seen, false);

  { 2. -Fu / -Fi + SourceDirs }
  QOScanList(GetSourceDirectories, AllItems, seen, false);

  Dispose(seen, Done);
  TotalCount := AllItems^.Count;
end;

{ Wide corpus: same dirs as ScanCorpus but ignores QuickOpenRec.IncludeMask,
  so files like play.log show up. Built lazily on the first keystroke that
  introduces a '.' into the query, then reused. Disposed in Done. }
procedure TQuickOpenDialog.ScanWideCorpus;
var
  seen    : PUnsortedStringCollection;
  projDir : string;
begin
  if WideItems <> nil then
  begin
    Dispose(WideItems, Done);
    WideItems := nil;
  end;
  New(WideItems, Init(64, 64));
  New(seen, Init(64, 64));

  if PrimaryFile <> '' then
    projDir := DirOf(FExpand(PrimaryFile))
  else
    GetDir(0, projDir);
  QOScanDir(TrimEndSlash(projDir), WideItems, seen, true);
  QOScanList(GetSourceDirectories, WideItems, seen, true);

  Dispose(seen, Done);
  WideScanned := true;
end;

{ Resolve Q against the same dirs as the wide corpus. Returns the absolute
  path of the first existing file whose basename literally equals Q (or
  whose absolute/relative form matches). Used as a fallback when the user
  presses Enter on a query containing '.' that has no matches in the
  listbox -- e.g. typing 'play.log' on an IDE configured with the default
  *.pas;*.inc;... mask. }
function TQuickOpenDialog.TryResolveLiteralPath(const Q: string;
                                                var FullOut: string): boolean;
var
  candidate : string;
  projDir   : string;
  paths     : string;
  i, j, lm  : Sw_Integer;
  piece     : string;
begin
  TryResolveLiteralPath := false;
  FullOut := '';
  if Q = '' then exit;

  { Absolute path or path relative to cwd. }
  candidate := FExpand(Q);
  if ExistsFile(candidate) then
  begin
    FullOut := candidate;
    TryResolveLiteralPath := true;
    exit;
  end;

  { Project / primary-file directory. }
  if PrimaryFile <> '' then
  begin
    projDir := TrimEndSlash(DirOf(FExpand(PrimaryFile)));
    if projDir <> '' then
    begin
      candidate := FExpand(projDir + '\' + Q);
      if ExistsFile(candidate) then
      begin
        FullOut := candidate;
        TryResolveLiteralPath := true;
        exit;
      end;
    end;
  end;

  { -Fu / -Fi + SourceDirs, semicolon-separated. }
  paths := GetSourceDirectories;
  lm := Length(paths);
  i := 1;
  while i <= lm do
  begin
    j := i;
    while (j <= lm) and (paths[j] <> ';') do Inc(j);
    piece := Copy(paths, i, j - i);
    { Qualify System.Delete -- inside this method 'Delete' would resolve
      to TGroup.Delete(PView) and fail to overload. }
    while (Length(piece) > 0) and (piece[1] = ' ') do System.Delete(piece, 1, 1);
    while (Length(piece) > 0) and (piece[Length(piece)] = ' ') do
      System.Delete(piece, Length(piece), 1);
    if piece <> '' then
    begin
      candidate := FExpand(TrimEndSlash(FExpand(piece)) + '\' + Q);
      if ExistsFile(candidate) then
      begin
        FullOut := candidate;
        TryResolveLiteralPath := true;
        exit;
      end;
    end;
    i := j + 1;
  end;
end;

{ Insertion sort the filter list in place. Ascending by
  (Score, KeyA, ExtPri, DisplayDir). KeyA before ExtPri means
  encode.pas + encode.ini list together (both stem 'ENCODE'),
  with .pas first within that pair. N is small (<= TotalCount,
  typically a few hundred). }
procedure QOSortFilter(C: PQuickOpenFilterList);
  function Less(a, b: PQuickOpenItem): boolean;
  var ka, kb, da, db: string;
  begin
    if a^.Score <> b^.Score then
    begin
      Less := a^.Score < b^.Score;
      exit;
    end;
    if a^.KeyA <> nil then ka := a^.KeyA^ else ka := '';
    if b^.KeyA <> nil then kb := b^.KeyA^ else kb := '';
    if ka <> kb then
    begin
      Less := ka < kb;
      exit;
    end;
    if a^.ExtPri <> b^.ExtPri then
    begin
      Less := a^.ExtPri < b^.ExtPri;
      exit;
    end;
    if a^.DisplayDir <> nil then da := a^.DisplayDir^ else da := '';
    if b^.DisplayDir <> nil then db := b^.DisplayDir^ else db := '';
    Less := QOUpper(da) < QOUpper(db);
  end;
var
  i, j: Sw_Integer;
  a, b: PQuickOpenItem;
begin
  for i := 1 to C^.Count - 1 do
  begin
    a := PQuickOpenItem(C^.At(i));
    j := i;
    while j > 0 do
    begin
      b := PQuickOpenItem(C^.At(j - 1));
      if Less(a, b) then
      begin
        C^.AtPut(j, b);
        Dec(j);
      end
      else break;
    end;
    C^.AtPut(j, a);
  end;
end;

procedure TQuickOpenDialog.Refilter;
var
  q, qRaw   : string;
  i         : Sw_Integer;
  item      : PQuickOpenItem;
  keep      : boolean;
  score     : byte;
  filt      : PQuickOpenFilterList;
  shown, tot: Sw_Integer;
  status    : string;
  byName    : boolean;
  source    : PQuickOpenOwnedList;
  nameUp    : string;
begin
  if (ListBox = nil) or (Counts = nil) or (Input = nil) then
    exit;
  if Input^.Data <> nil then
    qRaw := Input^.Data^
  else
    qRaw := '';
  q := QOUpper(qRaw);

  { A '.' in the query means the user is typing a literal filename
    (e.g. 'play.log'). Switch to a mask-ignoring corpus and match
    against the full basename instead of the stem. }
  byName := Pos('.', qRaw) > 0;
  if byName then
  begin
    if not WideScanned then ScanWideCorpus;
    source := WideItems;
  end
  else
    source := AllItems;
  if source = nil then exit;

  New(filt, Init(32, 64));
  for i := 0 to source^.Count - 1 do
  begin
    item := PQuickOpenItem(source^.At(i));
    if item = nil then continue;
    keep := false;
    score := 0;
    if q = '' then
    begin
      keep := true;
    end
    else if byName then
    begin
      if item^.DisplayName <> nil then
        nameUp := QOUpper(item^.DisplayName^)
      else
        nameUp := '';
      if QOHasPrefix(q, nameUp) then
        keep := true;
    end
    else if (item^.KeyA <> nil) and QOHasPrefix(q, item^.KeyA^) then
    begin
      keep := true;
      score := 0;
    end
    else if (item^.KeyB <> nil) and (item^.KeyA <> nil) and
            (item^.KeyB^ <> item^.KeyA^) and
            QOHasPrefix(q, item^.KeyB^) then
    begin
      keep := true;
      score := 1;
    end;
    if keep then
    begin
      item^.Score := score;
      filt^.Insert(item);
    end;
  end;
  QOSortFilter(filt);

  shown := filt^.Count;
  if byName then
    tot := source^.Count
  else
    tot := TotalCount;

  ListBox^.NewList(filt);
  if shown > 0 then ListBox^.FocusItem(0);

  { Update status text: "N of M" or a friendly empty message. }
  if tot = 0 then
    status := label_openbyname_empty
  else if shown = 0 then
    status := label_openbyname_nomatches
  else
  begin
    ClearFormatParams;
    AddFormatParamInt(shown);
    AddFormatParamInt(tot);
    FormatStr(status, label_openbyname_counts, FormatParams);
  end;
  if Counts^.Text <> nil then DisposeStr(Counts^.Text);
  Counts^.Text := NewStr(status);
  Counts^.DrawView;
end;

function TQuickOpenDialog.ChosenPath: string;
var
  idx : Sw_Integer;
  lst : PCollection;
  p   : PQuickOpenItem;
begin
  ChosenPath := '';
  if FallbackPath <> '' then
  begin
    ChosenPath := FallbackPath;
    exit;
  end;
  if (ListBox = nil) or (ListBox^.List = nil) then exit;
  lst := ListBox^.List;
  idx := ListBox^.Focused;
  if (idx < 0) or (idx >= lst^.Count) then exit;
  p := PQuickOpenItem(lst^.At(idx));
  if (p <> nil) and (p^.FullPath <> nil) then
    ChosenPath := p^.FullPath^;
end;

{----------------------------------------------------------------}
{  Top-level entry — dispatched from cmOpenByName in HandleEvent }
{----------------------------------------------------------------}

procedure TIDEApp.OpenByName;
var
  D        : PQuickOpenDialog;
  chosen   : string;
  savedMask: string;
  res      : Word;
  existing : PSourceWindow;
  src      : PSourceWindow;
begin
  { Snapshot the persisted mask so a Cancel reverts any edits the
    user made to the textbox; OK keeps the new mask. }
  savedMask := QuickOpenRec.IncludeMask;
  New(D, Init);
  D^.ScanCorpus;
  D^.Refilter;
  res := Application^.ExecView(D);
  chosen := '';
  if res = cmOK then
  begin
    chosen := D^.ChosenPath;
    if D^.MaskInput <> nil then
      QuickOpenRec.IncludeMask := D^.MaskInput^.Data^;
  end
  else
    QuickOpenRec.IncludeMask := savedMask;
  Dispose(D, Done);
  if (res <> cmOK) or (chosen = '') then exit;

  { Focus an already-open editor window for this file if one exists.
    SearchWindow matches on the window title, which may be shortened
    (e.g. basename only) and so miss absolute-path matches. Use
    SearchOnDesktop, which compares against Editor^.FileName. }
  existing := SearchOnDesktop(chosen, false);
  if existing <> nil then
  begin
    existing^.Select;
    existing^.MakeFirst;
    AddRecentFile(chosen, 0, 0);
    exit;
  end;

  src := OpenEditorWindow(nil, chosen, 0, 0);
  if src <> nil then
    AddRecentFile(chosen, 0, 0);
end;
