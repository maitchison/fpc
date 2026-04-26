{
    This file is part of the Free Pascal Integrated Development Environment

    Alt+Up / Alt+Down: jump between a routine's interface declaration and
    its implementation, anywhere within the same source unit.

    From any line inside a procedure / function / constructor / destructor
    body in the implementation section, Alt+Up walks up to find the
    enclosing routine header, then jumps to its forward declaration in
    the interface section. Alt+Down does the inverse.

    Methods are recognised by walking up from the routine header to the
    enclosing `T = class | object | interface | record` block.

    A small "bounce" memory pairs the two directions: Alt+Up immediately
    followed by Alt+Down (or vice versa) restores the exact prior cursor
    position rather than landing at the start of the routine. The bounce
    is invalidated as soon as the cursor moves to a different line.

    Failures are surfaced via FlashEditorStatus -- a transient line
    painted over the bottom of the screen -- and never via a modal popup.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
unit FPDeclImpl;

{$H-}

interface

uses
  Objects,
  FPViews;

procedure DeclImplJumpUp(Ed: PSourceEditor);
procedure DeclImplJumpDown(Ed: PSourceEditor);

procedure DeclImplResetBounce;

implementation

uses
  WEditor,
  FPUtils,
  FPNavStk;

type
  THeaderInfo = record
    Y         : sw_integer;  { 0-based line of the header }
    Kind      : string[16];  { lowercased: procedure/function/constructor/destructor }
    ClassName : string;      { '' if not a method }
    Name      : string;      { unqualified routine name }
    NameX     : sw_integer;  { 0-based column where the (qualified) name starts }
  end;

var
  Bounce: record
    Active : boolean;
    AFile  : string;
    AX, AY : sw_integer;       { side A position }
    BFile  : string;
    BX, BY : sw_integer;       { side B position }
  end;

procedure DeclImplResetBounce;
begin
  Bounce.Active := false;
  Bounce.AFile := '';
  Bounce.BFile := '';
end;

{ ----- char/string scratch helpers ----- }

function IsIdentStart(c: AnsiChar): boolean;
begin
  IsIdentStart := (c in ['A'..'Z','a'..'z','_']);
end;

function IsIdentCont(c: AnsiChar): boolean;
begin
  IsIdentCont := (c in ['A'..'Z','a'..'z','_','0'..'9']);
end;

procedure SkipWS(const S: string; var P: sw_integer);
begin
  while (P <= length(S)) and ((S[P] = ' ') or (S[P] = #9)) do
    Inc(P);
end;

function ScanIdent(const S: string; var P: sw_integer): string;
var
  StartP: sw_integer;
begin
  StartP := P;
  if (P <= length(S)) and IsIdentStart(S[P]) then
    Inc(P);
  while (P <= length(S)) and IsIdentCont(S[P]) do
    Inc(P);
  ScanIdent := Copy(S, StartP, P - StartP);
end;

function StripCommentsAndStrings(const S: string): string;
{ Replace { ... }, (* ... *), // ..., and string contents with spaces of the
  same length so column positions stay aligned. Comments that span lines
  are still chopped at end-of-line — good enough for header detection,
  since procedure headers don't sit inside a multi-line comment in
  well-formed code. }
var
  i: sw_integer;
  R: string;
  InString: boolean;
  InBrace, InParenStar: boolean;
begin
  R := S;
  InString := false;
  InBrace := false;
  InParenStar := false;
  i := 1;
  while i <= length(R) do
    begin
      if InBrace then
        begin
          if R[i] = '}' then InBrace := false;
          R[i] := ' ';
          Inc(i);
          continue;
        end;
      if InParenStar then
        begin
          if (i < length(R)) and (R[i] = '*') and (R[i+1] = ')') then
            begin
              R[i] := ' '; R[i+1] := ' ';
              InParenStar := false;
              Inc(i, 2);
              continue;
            end;
          R[i] := ' ';
          Inc(i);
          continue;
        end;
      if InString then
        begin
          if R[i] = '''' then
            begin
              if (i < length(R)) and (R[i+1] = '''') then
                begin
                  R[i] := ' '; R[i+1] := ' ';
                  Inc(i, 2);
                  continue;
                end;
              InString := false;
              R[i] := ' ';
              Inc(i);
              continue;
            end;
          R[i] := ' ';
          Inc(i);
          continue;
        end;
      if R[i] = '{' then
        begin
          InBrace := true; R[i] := ' '; Inc(i); continue;
        end;
      if (i < length(R)) and (R[i] = '(') and (R[i+1] = '*') then
        begin
          InParenStar := true;
          R[i] := ' '; R[i+1] := ' ';
          Inc(i, 2);
          continue;
        end;
      if (i < length(R)) and (R[i] = '/') and (R[i+1] = '/') then
        begin
          while i <= length(R) do
            begin R[i] := ' '; Inc(i); end;
          break;
        end;
      if R[i] = '''' then
        begin
          InString := true; R[i] := ' '; Inc(i); continue;
        end;
      Inc(i);
    end;
  StripCommentsAndStrings := R;
end;

function FirstColumn(const S: string): sw_integer;
{ 1-based column of first non-whitespace character; 0 if blank. }
var
  i: sw_integer;
begin
  for i := 1 to length(S) do
    if (S[i] <> ' ') and (S[i] <> #9) then
      begin
        FirstColumn := i;
        exit;
      end;
  FirstColumn := 0;
end;

function IsRoutineKindKeyword(const Lo: string): boolean;
begin
  IsRoutineKindKeyword :=
    (Lo = 'procedure') or (Lo = 'function') or
    (Lo = 'constructor') or (Lo = 'destructor');
end;

{ Try to parse Line as a routine header. Returns true on success. NameX is
  0-based column of the start of the routine name (the part after `class
  procedure `, possibly including `ClassName.`). Stripped is Line with
  comments and string contents blanked. }
function ParseHeader(const Stripped: string;
  var Kind, ClassName, RoutineName: string;
  var NameX: sw_integer): boolean;
var
  P, NamePos: sw_integer;
  T, Lo, A: string;
begin
  ParseHeader := false;
  Kind := ''; ClassName := ''; RoutineName := ''; NameX := 0;
  P := 1;
  SkipWS(Stripped, P);
  T := ScanIdent(Stripped, P);
  if T = '' then exit;
  Lo := LowerCaseStr(T);
  if Lo = 'class' then
    begin
      SkipWS(Stripped, P);
      T := ScanIdent(Stripped, P);
      if T = '' then exit;
      Lo := LowerCaseStr(T);
    end;
  if not IsRoutineKindKeyword(Lo) then exit;
  Kind := Lo;
  SkipWS(Stripped, P);
  NamePos := P;
  A := ScanIdent(Stripped, P);
  if A = '' then exit;
  if (P <= length(Stripped)) and (Stripped[P] = '.') then
    begin
      Inc(P);
      ClassName := A;
      A := ScanIdent(Stripped, P);
      if A = '' then exit;
    end;
  RoutineName := A;
  NameX := NamePos - 1;  { 0-based for editor coords }
  ParseHeader := true;
end;

{ Returns true if Line introduces a class/object/interface/record block,
  e.g. "  TFoo = class(TBar)". Forward type aliases like "TFoo = class;"
  and metatype "class of TBar" do NOT open a block. }
function LineOpensClassBlock(const Stripped: string; var CName: string): boolean;
var
  P: sw_integer;
  A, K, Next: string;
begin
  LineOpensClassBlock := false;
  CName := '';
  P := 1;
  SkipWS(Stripped, P);
  A := ScanIdent(Stripped, P);
  if A = '' then exit;
  SkipWS(Stripped, P);
  if (P > length(Stripped)) or (Stripped[P] <> '=') then exit;
  Inc(P);
  SkipWS(Stripped, P);
  K := LowerCaseStr(ScanIdent(Stripped, P));
  if (K <> 'class') and (K <> 'object') and
     (K <> 'interface') and (K <> 'record') then exit;
  SkipWS(Stripped, P);
  if (P <= length(Stripped)) and (Stripped[P] = ';') then exit; { forward type alias }
  if K = 'class' then
    begin
      Next := LowerCaseStr(ScanIdent(Stripped, P));
      if Next = 'of' then exit;
      { Note: `class abstract`, `class sealed`, `class(parent)` all open blocks. }
    end;
  CName := A;
  LineOpensClassBlock := true;
end;

function LineIsBareEnd(const Stripped: string): boolean;
{ Detects a top-of-class-block terminator: line whose first identifier is `end`
  followed by an optional `;` and nothing else interesting. }
var
  P: sw_integer;
  A: string;
begin
  LineIsBareEnd := false;
  P := 1;
  SkipWS(Stripped, P);
  A := LowerCaseStr(ScanIdent(Stripped, P));
  if A <> 'end' then exit;
  LineIsBareEnd := true;
end;

function LineFirstIdent(const Stripped: string): string;
var
  P: sw_integer;
begin
  P := 1;
  SkipWS(Stripped, P);
  LineFirstIdent := LowerCaseStr(ScanIdent(Stripped, P));
end;

{ ----- editor scanning ----- }

function FindKeywordLine(Ed: PSourceEditor; FromY, ToY: sw_integer; const KW: string): sw_integer;
var
  i: sw_integer;
  S: string;
begin
  FindKeywordLine := -1;
  if not Assigned(Ed) then exit;
  for i := FromY to ToY do
    begin
      if i >= Ed^.GetLineCount then break;
      S := StripCommentsAndStrings(Ed^.GetLineText(i));
      if LineFirstIdent(S) = KW then
        begin
          FindKeywordLine := i;
          exit;
        end;
    end;
end;

function FindImplementationStart(Ed: PSourceEditor): sw_integer;
begin
  FindImplementationStart :=
    FindKeywordLine(Ed, 0, Ed^.GetLineCount - 1, 'implementation');
end;

function FindInterfaceStart(Ed: PSourceEditor): sw_integer;
begin
  FindInterfaceStart :=
    FindKeywordLine(Ed, 0, Ed^.GetLineCount - 1, 'interface');
end;

{ Walk up from CurY looking for a routine header. Stops at SectionStart
  (the line of the `interface` or `implementation` keyword); if no header
  is found before reaching it, returns false.

  When TopLevelOnly is true, only accepts headers at column 1 (indent 0).
  This skips nested functions inside an implementation body. }
function FindEnclosingHeader(Ed: PSourceEditor;
  CurY, SectionStart: sw_integer;
  TopLevelOnly: boolean;
  var H: THeaderInfo): boolean;
var
  i: sw_integer;
  S, Stripped: string;
  Kind, Cls, Name: string;
  Col, NX: sw_integer;
begin
  FindEnclosingHeader := false;
  FillChar(H, SizeOf(H), 0);
  H.Kind := ''; H.ClassName := ''; H.Name := '';
  i := CurY;
  while (i >= 0) and (i > SectionStart) do
    begin
      S := Ed^.GetLineText(i);
      Stripped := StripCommentsAndStrings(S);
      Col := FirstColumn(Stripped);
      if Col > 0 then
        if (not TopLevelOnly) or (Col = 1) then
          if ParseHeader(Stripped, Kind, Cls, Name, NX) then
            begin
              H.Y := i;
              H.Kind := Kind;
              H.ClassName := Cls;
              H.Name := Name;
              H.NameX := NX;
              FindEnclosingHeader := true;
              exit;
            end;
      Dec(i);
    end;
end;

{ In the interface section, walk up from HdrY-1 to find the most recent
  `T = class|object|interface|record` block opener whose block has not
  yet closed. Naive version: walks up, returns the first opener seen that
  is not preceded (going downward toward HdrY) by a balancing `end;` --
  but we only need it when the routine header itself is unqualified, so
  approximate with: find the most recent opener; assume we're inside it. }
function FindEnclosingClass(Ed: PSourceEditor;
  HdrY, IntfStart: sw_integer;
  var CName: string): boolean;
var
  i, EndsSeen: sw_integer;
  S, Stripped, Tmp: string;
begin
  FindEnclosingClass := false;
  CName := '';
  EndsSeen := 0;
  i := HdrY - 1;
  while (i >= 0) and (i >= IntfStart) do
    begin
      S := Ed^.GetLineText(i);
      Stripped := StripCommentsAndStrings(S);
      if LineIsBareEnd(Stripped) then
        Inc(EndsSeen)
      else if LineOpensClassBlock(Stripped, Tmp) then
        begin
          if EndsSeen = 0 then
            begin
              CName := Tmp;
              FindEnclosingClass := true;
              exit;
            end
            else Dec(EndsSeen);
        end;
      Dec(i);
    end;
end;

function StrEqI(const A, B: string): boolean;
begin
  StrEqI := LowerCaseStr(A) = LowerCaseStr(B);
end;

function FindRoutineInImpl(Ed: PSourceEditor;
  ImplStartY: sw_integer;
  const ClsName, RoutineName: string;
  var HitY, HitX: sw_integer): boolean;
var
  i, Last: sw_integer;
  S, Stripped: string;
  K, C, N: string;
  NX: sw_integer;
begin
  FindRoutineInImpl := false;
  HitY := -1; HitX := 0;
  Last := Ed^.GetLineCount - 1;
  for i := ImplStartY + 1 to Last do
    begin
      Stripped := StripCommentsAndStrings(Ed^.GetLineText(i));
      if FirstColumn(Stripped) = 1 then
        if ParseHeader(Stripped, K, C, N, NX) then
          if StrEqI(N, RoutineName) and StrEqI(C, ClsName) then
            begin
              HitY := i;
              HitX := NX;
              FindRoutineInImpl := true;
              exit;
            end;
    end;
end;

function FindRoutineInIntf(Ed: PSourceEditor;
  IntfStartY, ImplStartY: sw_integer;
  const ClsName, RoutineName: string;
  var HitY, HitX: sw_integer): boolean;
var
  i, Limit, Depth: sw_integer;
  Stripped, OpenedCls, K, C, N: string;
  NX: sw_integer;
  InTargetClass: boolean;
  Tmp: string;
begin
  FindRoutineInIntf := false;
  HitY := -1; HitX := 0;
  Depth := 0;
  InTargetClass := false;
  if ImplStartY < 0 then
    Limit := Ed^.GetLineCount - 1
  else
    Limit := ImplStartY - 1;
  for i := IntfStartY to Limit do
    begin
      Stripped := StripCommentsAndStrings(Ed^.GetLineText(i));
      if LineIsBareEnd(Stripped) and (Depth > 0) then
        begin
          Dec(Depth);
          if Depth = 0 then InTargetClass := false;
          continue;
        end;
      if LineOpensClassBlock(Stripped, OpenedCls) then
        begin
          Inc(Depth);
          if (Depth = 1) and (ClsName <> '') and StrEqI(OpenedCls, ClsName) then
            InTargetClass := true;
          continue;
        end;
      if ParseHeader(Stripped, K, C, N, NX) then
        begin
          if ClsName = '' then
            begin
              { Plain function/procedure: only match outside any class block,
                and only when the interface header is unqualified. }
              if (Depth = 0) and (C = '') and StrEqI(N, RoutineName) then
                begin
                  HitY := i; HitX := NX;
                  FindRoutineInIntf := true;
                  exit;
                end;
            end
          else
            begin
              { Method: match the unqualified declaration inside the right class block. }
              if InTargetClass and (C = '') and StrEqI(N, RoutineName) then
                begin
                  HitY := i; HitX := NX;
                  FindRoutineInIntf := true;
                  exit;
                end;
              { Also accept fully-qualified `ClassName.Routine` in interface
                (rare but legal in some dialects). }
              if (Depth = 0) and StrEqI(C, ClsName) and StrEqI(N, RoutineName) then
                begin
                  HitY := i; HitX := NX;
                  FindRoutineInIntf := true;
                  exit;
                end;
            end;
        end;
    end;
end;

{ ----- jumping + bounce ----- }

procedure JumpEditor(Ed: PSourceEditor; X, Y: sw_integer);
begin
  Ed^.SetCurPtr(X, Y);
  Ed^.TrackCursor(do_centre);
end;

procedure SetBounce(const FA: string; AX, AY: sw_integer;
                    const FB: string; BX, BY: sw_integer);
begin
  Bounce.Active := true;
  Bounce.AFile := FA; Bounce.AX := AX; Bounce.AY := AY;
  Bounce.BFile := FB; Bounce.BX := BX; Bounce.BY := BY;
end;

{ Try to consume the bounce by treating (CurFile,CurY) as one of the two
  recorded sides; if it is, jump to the OTHER side and rotate the bounce
  so the next press returns. The match tolerates the user moving within
  the same line (Y must match exactly, X is irrelevant). Returns true if
  the bounce was used. }
function TryConsumeBounce(Ed: PSourceEditor;
  const CurFile: string; CurX, CurY: sw_integer): boolean;
begin
  TryConsumeBounce := false;
  if not Bounce.Active then exit;
  if StrEqI(CurFile, Bounce.AFile) and (CurY = Bounce.AY) then
    begin
      JumpEditor(Ed, Bounce.BX, Bounce.BY);
      { Now re-anchor: the new "side A" is the place we just left, but we
        keep its original X so a subsequent reverse press lands exactly
        where we did. }
      Bounce.AX := CurX;  { remember where the user actually was on that line }
      TryConsumeBounce := true;
      exit;
    end;
  if StrEqI(CurFile, Bounce.BFile) and (CurY = Bounce.BY) then
    begin
      JumpEditor(Ed, Bounce.AX, Bounce.AY);
      Bounce.BX := CurX;
      TryConsumeBounce := true;
      exit;
    end;
end;

procedure DeclImplJumpUp(Ed: PSourceEditor);
var
  IntfY, ImplY: sw_integer;
  Hdr: THeaderInfo;
  CurFile: string;
  CurX, CurY: sw_integer;
  ClsName, EffectiveCls: string;
  HitY, HitX: sw_integer;
begin
  if not Assigned(Ed) then exit;
  CurFile := Ed^.FileName;
  CurX := Ed^.CurPos.X;
  CurY := Ed^.CurPos.Y;

  if TryConsumeBounce(Ed, CurFile, CurX, CurY) then exit;

  IntfY := FindInterfaceStart(Ed);
  ImplY := FindImplementationStart(Ed);

  if ImplY < 0 then
    begin
      FlashEditorStatus('Decl/impl jump: no `implementation` keyword in this unit');
      exit;
    end;
  if CurY <= ImplY then
    begin
      FlashEditorStatus('Decl/impl jump: already in interface section (Alt+Down to go to implementation)');
      exit;
    end;

  if not FindEnclosingHeader(Ed, CurY, ImplY, true, Hdr) then
    begin
      FlashEditorStatus('Decl/impl jump: cursor is not inside a procedure or function body');
      exit;
    end;

  { Resolve class name for the lookup in the interface section. }
  if Hdr.ClassName <> '' then
    EffectiveCls := Hdr.ClassName
  else
    EffectiveCls := '';

  if not FindRoutineInIntf(Ed, IntfY + 1, ImplY, EffectiveCls, Hdr.Name, HitY, HitX) then
    begin
      if EffectiveCls <> '' then
        FlashEditorStatus('Decl/impl jump: no interface declaration for ' + EffectiveCls + '.' + Hdr.Name)
      else
        FlashEditorStatus('Decl/impl jump: no interface declaration for ' + Hdr.Name);
      exit;
    end;

  NavStackPush(CurFile, CurX, CurY);
  SetBounce(CurFile, CurX, CurY, CurFile, HitX, HitY);
  JumpEditor(Ed, HitX, HitY);
end;

procedure DeclImplJumpDown(Ed: PSourceEditor);
var
  IntfY, ImplY: sw_integer;
  Hdr: THeaderInfo;
  CurFile: string;
  CurX, CurY: sw_integer;
  ClsName, EffectiveCls: string;
  HitY, HitX: sw_integer;
begin
  if not Assigned(Ed) then exit;
  CurFile := Ed^.FileName;
  CurX := Ed^.CurPos.X;
  CurY := Ed^.CurPos.Y;

  if TryConsumeBounce(Ed, CurFile, CurX, CurY) then exit;

  IntfY := FindInterfaceStart(Ed);
  ImplY := FindImplementationStart(Ed);

  if ImplY < 0 then
    begin
      FlashEditorStatus('Decl/impl jump: no `implementation` keyword in this unit');
      exit;
    end;
  if CurY > ImplY then
    begin
      FlashEditorStatus('Decl/impl jump: already in implementation section (Alt+Up to go to interface)');
      exit;
    end;

  { In the interface section, accept any indent — methods live indented
    inside class blocks. }
  if not FindEnclosingHeader(Ed, CurY, IntfY, false, Hdr) then
    begin
      FlashEditorStatus('Decl/impl jump: cursor is not on a procedure or function declaration');
      exit;
    end;

  { If header is unqualified, walk up to find an enclosing class block. }
  if Hdr.ClassName <> '' then
    EffectiveCls := Hdr.ClassName
  else
    if FindEnclosingClass(Ed, Hdr.Y, IntfY, ClsName) then
      EffectiveCls := ClsName
    else
      EffectiveCls := '';

  if not FindRoutineInImpl(Ed, ImplY, EffectiveCls, Hdr.Name, HitY, HitX) then
    begin
      if EffectiveCls <> '' then
        FlashEditorStatus('Decl/impl jump: no implementation found for ' + EffectiveCls + '.' + Hdr.Name)
      else
        FlashEditorStatus('Decl/impl jump: no implementation found for ' + Hdr.Name);
      exit;
    end;

  NavStackPush(CurFile, CurX, CurY);
  SetBounce(CurFile, CurX, CurY, CurFile, HitX, HitY);
  JumpEditor(Ed, HitX, HitY);
end;

initialization
  DeclImplResetBounce;

end.
