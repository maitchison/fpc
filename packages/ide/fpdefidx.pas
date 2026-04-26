{
    This file is part of the Free Pascal Integrated Development Environment

    Symbol-definition lookup adapter over the compiler's browser-info
    collection (BrowCol). Wraps "find every symbol named X across every
    loaded module" into a single call returning {file,line,col} records,
    plus per-source-file mtime tracking so callers can flag stale results.

    Browser data is populated by a successful compile-with-browser-info
    (Options|Compiler|Browser, or Compile|Make/Build with the -b switch).
    DefIndexAvailable returns false until that has happened at least once
    in this IDE session.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
unit FPDefIdx;

{$H-}

interface

uses
  Objects;

type
  PDefMatch = ^TDefMatch;
  TDefMatch = record
    FileName : PString;
    Line, Col: sw_integer;       { 1-based, as stored in BrowCol }
    SymKind  : PString;          { 'procedure', 'class', 'type', ... }
    SymName  : PString;          { for picker display }
    Owner    : PString;          { containing module or class name }
    Stale    : boolean;          { source file mtime > snapshot time }
  end;

  PDefMatchList = ^TDefMatchList;
  TDefMatchList = object(TCollection)
    function At(Index: sw_integer): PDefMatch;
    procedure FreeItem(Item: Pointer); virtual;
  end;

function DefIndexAvailable: boolean;
{ True iff a successful compile-with-browser-info has populated BrowCol. }

function DefIndexResolve(const Name: string): PDefMatchList;
{ Returns a newly-allocated list of matches; caller must Dispose it.
  Returns nil if no symbol info is loaded. Returns an empty list if
  symbol info is loaded but no symbol matches the given name.
  Name is matched case-insensitively against the unqualified identifier. }

procedure DefIndexSnapshotMTimes;
{ Captures current FileAge() of every source file referenced by BrowCol.
  Call once after a successful compile, before the user does anything that
  could re-touch source files. }

function DefIndexFileIsStale(const FileName: string): boolean;
{ True if FileName's current mtime is newer than the snapshot, OR if no
  snapshot exists for it. Comparison is case-insensitive. }

procedure DefIndexClearMTimes;

implementation

uses
  Dos,
  WUtils,
  BrowCol;

{----------------------------------------------------------------}
{  TDefMatchList                                                 }
{----------------------------------------------------------------}

function TDefMatchList.At(Index: sw_integer): PDefMatch;
begin
  At:=PDefMatch(inherited At(Index));
end;

procedure TDefMatchList.FreeItem(Item: Pointer);
var p: PDefMatch;
begin
  if Item=nil then exit;
  p:=PDefMatch(Item);
  if p^.FileName<>nil then DisposeStr(p^.FileName);
  if p^.SymKind <>nil then DisposeStr(p^.SymKind);
  if p^.SymName <>nil then DisposeStr(p^.SymName);
  if p^.Owner   <>nil then DisposeStr(p^.Owner);
  Dispose(p);
end;

{----------------------------------------------------------------}
{  mtime snapshot                                                }
{----------------------------------------------------------------}

const
  MaxMTimeFiles = 512;

type
  TMTimeEntry = record
    Name: PString;     { upper-case path }
    Time: longint;
  end;

var
  MTimes      : array[0..MaxMTimeFiles-1] of TMTimeEntry;
  MTimeCount  : sw_integer;

function NormPath(const S: string): string;
var i: sw_integer; r: string;
begin
  r:=S;
  for i:=1 to Length(r) do
    if r[i]='/' then r[i]:='\';
  NormPath:=UpcaseStr(r);
end;

procedure DefIndexClearMTimes;
var i: sw_integer;
begin
  for i:=0 to MTimeCount-1 do
    if MTimes[i].Name<>nil then
      begin DisposeStr(MTimes[i].Name); MTimes[i].Name:=nil; end;
  MTimeCount:=0;
end;

procedure SnapshotOne(const FileName: string);
var f: file;
    age: longint;
    np: string;
    i: sw_integer;
begin
  if FileName='' then exit;
  if MTimeCount>=MaxMTimeFiles then exit;
  Assign(f, FileName);
{$I-} Reset(f, 1); {$I+}
  if IOResult<>0 then exit;
  GetFTime(f, age);
  Close(f);
  np:=NormPath(FileName);
  { Dedupe: if already snapshotted, refresh in place. }
  for i:=0 to MTimeCount-1 do
    if (MTimes[i].Name<>nil) and (MTimes[i].Name^=np) then
      begin MTimes[i].Time:=age; exit; end;
  MTimes[MTimeCount].Name:=NewStr(np);
  MTimes[MTimeCount].Time:=age;
  Inc(MTimeCount);
end;

procedure DefIndexSnapshotMTimes;
var
  i, j: sw_integer;
  M: PModuleSymbol;
  P: PString;
begin
  DefIndexClearMTimes;
  if BrowCol.Modules=nil then exit;
  for i:=0 to BrowCol.Modules^.Count-1 do
    begin
      M:=PModuleSymbol(BrowCol.Modules^.At(i));
      if M=nil then continue;
      if M^.MainSource<>nil then SnapshotOne(M^.MainSource^);
      if M^.SourceFiles<>nil then
        for j:=0 to M^.SourceFiles^.Count-1 do
          begin
            P:=PString(M^.SourceFiles^.At(j));
            if P<>nil then SnapshotOne(P^);
          end;
    end;
end;

function DefIndexFileIsStale(const FileName: string): boolean;
var
  np: string;
  i: sw_integer;
  f: file;
  age: longint;
begin
  DefIndexFileIsStale:=true;
  if FileName='' then exit;
  np:=NormPath(FileName);
  for i:=0 to MTimeCount-1 do
    if (MTimes[i].Name<>nil) and (MTimes[i].Name^=np) then
      begin
        Assign(f, FileName);
        {$I-} Reset(f, 1); {$I+}
        if IOResult<>0 then exit;
        GetFTime(f, age);
        Close(f);
        DefIndexFileIsStale:=age>MTimes[i].Time;
        exit;
      end;
  { No snapshot for this file => treat as stale. }
end;

{----------------------------------------------------------------}
{  Lookup                                                        }
{----------------------------------------------------------------}

function DefIndexAvailable: boolean;
begin
  DefIndexAvailable:=BrowCol.Modules<>nil;
end;

procedure AddSymMatch(List: PDefMatchList; S: PSymbol; const OwnerName: string);
var
  M: PDefMatch;
  R: PReference;
  fn: string;
begin
  if (S=nil) or (S^.References=nil) or (S^.References^.Count=0) then exit;
  R:=S^.References^.At(0);
  if R=nil then exit;
  fn:=R^.GetFileName;
  if fn='' then exit;
  New(M);
  FillChar(M^, SizeOf(M^), 0);
  M^.FileName:=NewStr(fn);
  M^.Line    :=R^.Position.Y;
  M^.Col     :=R^.Position.X;
  M^.SymName :=NewStr(S^.GetName);
  M^.SymKind :=NewStr(S^.GetTypeName);
  M^.Owner   :=NewStr(OwnerName);
  M^.Stale   :=DefIndexFileIsStale(fn);
  List^.Insert(M);
end;

function DefIndexResolve(const Name: string): PDefMatchList;
var
  Result: PDefMatchList;
  UpName: string;
  i, j, k: sw_integer;
  Module, Sym, Sub: PSymbol;
  ModName: string;
begin
  DefIndexResolve:=nil;
  if not DefIndexAvailable then exit;
  if Name='' then exit;
  UpName:=UpcaseStr(Name);

  New(Result, Init(8,8));

  for i:=0 to BrowCol.Modules^.Count-1 do
    begin
      Module:=BrowCol.Modules^.At(i);
      if Module=nil then continue;

      ModName:='';
      if Module^.Name<>nil then ModName:=Module^.Name^;

      { The module name itself may be the target (e.g. 'System'). }
      if (Module^.Name<>nil) and (UpcaseStr(Module^.Name^)=UpName) then
        AddSymMatch(Result, Module, '');

      if Module^.Items=nil then continue;

      for j:=0 to Module^.Items^.Count-1 do
        begin
          Sym:=Module^.Items^.At(j);
          if Sym=nil then continue;

          if (Sym^.Name<>nil) and (UpcaseStr(Sym^.Name^)=UpName) then
            AddSymMatch(Result, Sym, ModName);

          { One level of nesting: class methods, record fields, etc. }
          if Sym^.Items<>nil then
            for k:=0 to Sym^.Items^.Count-1 do
              begin
                Sub:=Sym^.Items^.At(k);
                if Sub=nil then continue;
                if (Sub^.Name<>nil) and (UpcaseStr(Sub^.Name^)=UpName) then
                  AddSymMatch(Result, Sub, Sym^.GetName);
              end;
        end;
    end;

  DefIndexResolve:=Result;
end;

initialization
  MTimeCount:=0;

finalization
  DefIndexClearMTimes;

end.
