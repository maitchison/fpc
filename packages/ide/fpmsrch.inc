{
    This file is part of the Free Pascal Integrated Development Environment
    Copyright (c) 1998 by Berczi Gabor

    Search menu entries

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}

function ProcedureDialog(S : string) : PDialog;
var D: PDialog;
    R,R1,R2: TRect;
    IL: PEditorInputLine;
begin
  R.Assign(0,0,40,8);
  New(D, Init(R, dialog_proceduredialog));
  with D^ do
  begin
    Options:=Options or ofCentered;
    GetExtent(R); R.Grow(-3,-2); R.B.Y:=R.A.Y+1;
    R1.Copy(R);
    R2.Copy(R); Inc(R2.A.Y);Inc(R2.B.Y);
    New(IL, Init(R2,255));
    Insert(IL);
    IL^.SetData(S);
    Insert(New(PLabel, Init(R1, label_enterproceduretofind, IL)));
    GetExtent(R); R.Grow(-8,-1); R.A.Y:=R.B.Y-2; R.B.X:=R.A.X+10;
    Insert(New(PButton, Init(R, button_OK, cmOK, bfDefault)));
    R.Move(15,0);
    Insert(New(PButton, Init(R, button_Cancel, cmCancel, bfNormal)));
  end;
  IL^.Select;
  ProcedureDialog:=D;
end;


procedure TIDEApp.FindProcedure;
var R: TRect;
    PB: PBrowserWindow;
    S: PSortedSymbolCollection;
    Overflow: boolean;
    ProcS : string;
    Level : longint;

  function NameMatches(const St : string) : boolean;
    begin
      NameMatches:=(ProcS='') or (Pos(ProcS,UpcaseStr(St)) > 0);
    end;

  procedure InsertInS(P: PSymbol);

    procedure InsertItemsInS(P: PSymbolCollection);
    var I: Sw_integer;
    begin
      for I:=0 to P^.Count-1 do
        InsertInS(P^.At(I));
    end;

  begin
    Inc(level);
    if S^.Count=MaxCollectionSize then
       begin Overflow:=true; Exit; end;
    if {(P^.typ = procsym) this needs symconst unit which I prefer to avoid }
       ((P^.GetTypeName='proc') or (P^.GetTypeName='func'))
       and NameMatches(P^.GetName) then
      S^.Insert(P);
    { this is wrong because it inserted args or locals of proc
      in the globals list !! PM}
    if (P^.Items<>nil) and (level=1) then
      InsertItemsInS(P^.Items);
    Dec(level);
  end;

var
    EditorWindow : PSourceWindow;
begin
  level:=0;
  if BrowCol.Modules=nil then
     begin ErrorBox(msg_nodebuginfoavailable,nil); Exit; end;
  EditorWindow:=FirstEditorWindow;
  If assigned(EditorWindow) then
    ProcS:=LowerCaseStr(EditorWindow^.Editor^.GetCurrentWord)
  else
    ProcS:='';
  if ExecuteDialog(ProcedureDialog(ProcS),@ProcS)=cmCancel then
    exit;
  ProcS:=UpcaseStr(ProcS);
  Overflow:=false;
  if assigned(ProcedureCollection) then
    begin
      ProcedureCollection^.deleteAll;
      Dispose(ProcedureCollection,done);
    end;
  New(S, Init(500,500));
  ProcedureCollection:=S;
  BrowCol.Modules^.ForEach(TCallbackProcParam(@InsertInS));
  if Overflow then
    WarningBox(msg_toomanysymbolscantdisplayall,nil);
  Desktop^.GetExtent(R); R.A.X:=R.B.X-35;
  PB:=New(PBrowserWindow, Init(R,
    label_sym_findprocedure,SearchFreeWindowNo,nil,label_sym_findprocedure2+ProcS,'',S,nil,nil,nil));
  Desktop^.Insert(PB);
  BrowserRoot^.InsertWindow(PB);
end;

procedure TIDEApp.Objects;
var PB : PBrowserWindow;
begin
  if ObjectTree=nil then
     begin ErrorBox(msg_nodebuginfoavailable,nil); Exit; end;

  PB:=OpenSymbolBrowser(0,0,0,0,label_sym_objects,label_sym_globalscope,nil,nil,nil,nil,ObjectTree,nil);
  BrowserRoot^.InsertWindow(PB);
end;

procedure TIDEApp.Globals;
var R: TRect;
    S: PSortedSymbolCollection;
    Overflow: boolean;
    Level : longint;
    PB : PBrowserWindow;

  procedure InsertInS(P: PSymbol);

    procedure InsertItemsInS(P: PSymbolCollection);
    var I: Sw_integer;
    begin
      for I:=0 to P^.Count-1 do
        InsertInS(P^.At(I));
    end;

  begin
    Inc(level);
    if S^.Count=MaxCollectionSize then
       begin Overflow:=true; Exit; end;
    S^.Insert(P);
    { this is wrong because it inserted args or locals of proc
      in the globals list !! PM}
    if (P^.Items<>nil) and (level=1) then
      InsertItemsInS(P^.Items);
    Dec(level);
  end;

begin
  level:=0;
  if BrowCol.Modules=nil then
     begin ErrorBox(msg_nodebuginfoavailable,nil); Exit; end;
  Overflow:=false;
  if assigned(GlobalsCollection) then
    begin
      GlobalsCollection^.deleteAll;
      Dispose(GlobalsCollection,done);
    end;
  New(S, Init(500,500));
  GlobalsCollection:=S;
  BrowCol.Modules^.ForEach(TCallbackProcParam(@InsertInS));
  if Overflow then
    WarningBox(msg_toomanysymbolscantdisplayall,nil);
  Desktop^.GetExtent(R); R.A.X:=R.B.X-35;
  PB:=New(PBrowserWindow, Init(R,
    label_sym_globals,SearchFreeWindowNo,nil,label_sym_globalscope,'',S,nil,nil,nil));
  Desktop^.Insert(PB);
  BrowserRoot^.InsertWindow(PB);
end;

procedure TIDEApp.Modules;
var
    R: TRect;
    S: PSortedSymbolCollection;
    PB : PBrowserWindow;
procedure InsertInS(P: PSymbol);
begin
  S^.Insert(P);
end;
begin
  if BrowCol.Modules=nil then
     begin ErrorBox(msg_nodebuginfoavailable,nil); Exit; end;
  if assigned(ModulesCollection) then
    begin
      ModulesCollection^.deleteAll;
      Dispose(ModulesCollection,done);
    end;
  New(S, Init(500,500));
  ModulesCollection:=S;
  BrowCol.Modules^.ForEach(TCallbackProcParam(@InsertInS));
  Desktop^.GetExtent(R); R.A.X:=R.B.X-35;
  PB:=New(PBrowserWindow, Init(R,
    dialog_units,SearchFreeWindowNo,nil,label_sym_globalscope,'',S,nil,nil,nil));
  Desktop^.Insert(PB);
  BrowserRoot^.InsertWindow(PB);
end;

function SymbolDialog(S : string) : PDialog;
var D: PDialog;
    R,R1,R2: TRect;
    IL: PEditorInputLine;
begin
  R.Assign(0,0,40,8);
  New(D, Init(R, dialog_browsesymbol));
  with D^ do
  begin
    Options:=Options or ofCentered;
    GetExtent(R); R.Grow(-3,-2); R.B.Y:=R.A.Y+1;
    R1.Copy(R);
    R2.Copy(R); Inc(R2.A.Y);Inc(R2.B.Y);
    New(IL, Init(R2,255));
    Insert(IL);
    IL^.SetData(S);
    Insert(New(PLabel, Init(R1, label_entersymboltobrowse, IL)));
    GetExtent(R); R.Grow(-8,-1); R.A.Y:=R.B.Y-2; R.B.X:=R.A.X+10;
    Insert(New(PButton, Init(R, button_OK, cmOK, bfDefault)));
    R.Move(15,0);
    Insert(New(PButton, Init(R, button_Cancel, cmCancel, bfNormal)));
  end;
  IL^.Select;
  SymbolDialog:=D;
end;

procedure TIDEApp.SearchSymbol;
var
    EditorWindow : PSourceWindow;
    S : string;
begin
  EditorWindow:=FirstEditorWindow;
  If assigned(EditorWindow) then
    S:=LowerCaseStr(EditorWindow^.Editor^.GetCurrentWord)
  else
    S:='';
  if ExecuteDialog(SymbolDialog(S),@S)<>cmCancel then
    OpenOneSymbolBrowser(S);
end;

procedure TIDEApp.DoJumpToAsm;
{ Jump from the current source line to the matching spot in the compiler-
  emitted .s listing. Requires the .s to have been written with -al so it
  contains "# [file]" and "# [NN] ..." comment markers. If the current
  source line has no asm of its own (comment / blank / decl line), lands
  on the first emitted line >= the current line. }
var
  EditorWin, AsmWin : PSourceWindow;
  SrcFile, AsmFile, AsmName, ExePath, ParentSrc : string;
  D : DirStr;
  N : NameStr;
  E : ExtStr;
  SrcLine, FoundLine, LineIdx, ParsedLine : longint;
  F : Text;
  Line, OurFileMarker : string;
  InOurFile, Sought : boolean;
  p : integer;

  function LocateAsm : string;
  begin
    if (ExePath<>'') and ExistsFile(ExePath+AsmName) then
      LocateAsm := ExePath+AsmName
    else if ExistsFile(D+AsmName) then
      LocateAsm := D+AsmName
    else
      LocateAsm := '';
  end;

begin
  EditorWin := FirstEditorWindow;
  if EditorWin = nil then
    begin ErrorBox('No source file open.',nil); Exit; end;
  SrcFile := EditorWin^.Editor^.FileName;
  SrcLine := EditorWin^.Editor^.CurPos.Y + 1;
  if SrcFile = '' then
    begin ErrorBox('Save the source file first.',nil); Exit; end;

  SrcFile := FExpand(SrcFile);
  FSplit(SrcFile,D,N,E);
  { Include files don't have their own .s -- the assembler emits a single .s
    per compiled unit, with `# [FILE.INC]` markers identifying include-file
    spans. Look up the parent unit via the browser-info collector and aim
    the .s lookup at it; the per-source marker matching below handles the
    rest. Falls back to the old FOO.S behaviour when no parent is found
    (e.g. browser info hasn't been built yet). }
  if (UpcaseStr(E) = '.INC') then
    begin
      ParentSrc := DefIndexFindIncludeParent(SrcFile);
      if ParentSrc <> '' then
        FSplit(FExpand(ParentSrc), D, N, E)
      else if not DefIndexAvailable then
        begin
          ErrorBox('Jump to asm: no browser info loaded -- compile the unit '+
                   'that includes '+NameAndExtOf(SrcFile)+
                   ' with Options|Compiler|Browser turned on, then retry.', nil);
          Exit;
        end;
      { If parent not found but browser info IS loaded, fall through with the
        original .inc-derived AsmName -- the user will get the usual "no .s"
        error and can investigate. }
    end;
  AsmName := N+'.s';
  ExePath := GetExePath;

  AsmFile := LocateAsm;
  if (AsmFile='') and AutoCompileAsm then
    begin
      DoCompile(cCompileAsm);
      AsmFile := LocateAsm;
    end;
  if AsmFile = '' then
    begin
      ErrorBox('No .s file for '+N+E+'. Compile with -al first.',nil);
      Exit;
    end;

  OurFileMarker := '# ['+UpcaseStr(NameAndExtOf(SrcFile))+']';
  FoundLine := 0;
  LineIdx := 0;
  InOurFile := false;
  Sought := false;

  {$I-}
  Assign(F,AsmFile);
  Reset(F);
  if IOResult<>0 then
    begin ErrorBox('Cannot open '+AsmFile,nil); Exit; end;
  while not Eof(F) and not Sought do
    begin
      ReadLn(F,Line);
      Inc(LineIdx);
      if (Length(Line)>=4) and (Line[1]='#') and (Line[2]=' ') and (Line[3]='[') then
        begin
          if Line[4] in ['0'..'9'] then
            begin
              if InOurFile then
                begin
                  ParsedLine := 0;
                  p := 4;
                  while (p<=Length(Line)) and (Line[p] in ['0'..'9']) do
                    begin
                      ParsedLine := ParsedLine*10 + Ord(Line[p]) - Ord('0');
                      Inc(p);
                    end;
                  if (p<=Length(Line)) and (Line[p]=']') and (ParsedLine >= SrcLine) then
                    begin
                      FoundLine := LineIdx;
                      Sought := true;
                    end;
                end;
            end
          else
            InOurFile := UpcaseStr(Line)=OurFileMarker;
        end;
    end;
  Close(F);
  if IOResult<>0 then ;
  {$I+}

  if FoundLine=0 then
    AsmWin := TryToOpenFile(nil,AsmFile,0,0,false)
  else
    AsmWin := TryToOpenFile(nil,AsmFile,0,FoundLine-1,false);
  if Assigned(AsmWin) then
    begin
      AsmWin^.Select;
      AsmWin^.Editor^.TrackCursor(do_centre);
    end;
end;


