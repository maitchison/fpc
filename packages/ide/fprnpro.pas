{
    This file is part of the Free Pascal Integrated Development Environment
    Copyright (c) 2026

    Run profiles for the IDE: named bundles of (main file, run parameters)
    that the user can switch between. Persisted in fp.ini under [RunProfiles].

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
{$I globdir.inc}
unit FPRnPro;

interface

uses Objects, Drivers, Views, Dialogs, App,
     WEditor, WViews,
     FPConst, FPViews;

const
     MaxRunProfileCount = 32;

type
    PRunProfile = ^TRunProfile;
    TRunProfile = object(TObject)
      constructor Init(const AName, AMainFile, AParams: string);
      function    GetName: string; virtual;
      function    GetMainFile: string; virtual;
      function    GetParams: string; virtual;
      procedure   GetAll(var AName, AMainFile, AParams: string); virtual;
      procedure   SetAll(const AName, AMainFile, AParams: string); virtual;
      destructor  Done; virtual;
    private
      Name     : PString;
      MainFile : PString;
      Params   : PString;
    end;

    PRunProfileCollection = ^TRunProfileCollection;
    TRunProfileCollection = object(TCollection)
      function At(Index: sw_Integer): PRunProfile;
    end;

    PRunProfileListBox = ^TRunProfileListBox;
    TRunProfileListBox = object(TAdvancedListBox)
      function GetText(Item, MaxLen: Sw_Integer): String; virtual;
    end;

    PRunProfileItemDialog = ^TRunProfileItemDialog;
    TRunProfileItemDialog = object(TCenterDialog)
      constructor Init(AProfile: PRunProfile);
      function    Execute: Word; virtual;
    private
      Profile  : PRunProfile;
      NameIL   : PEditorInputLine;
      MainIL   : PEditorInputLine;
      ParamIL  : PEditorInputLine;
    end;

    PRunProfilesDialog = ^TRunProfilesDialog;
    TRunProfilesDialog = object(TCenterDialog)
      constructor Init;
      function    Execute: Word; virtual;
      procedure   HandleEvent(var Event: TEvent); virtual;
    private
      ProfilesLB : PRunProfileListBox;
      procedure Add;
      procedure Edit;
      procedure Delete;
    end;

procedure InitRunProfiles;
function  GetRunProfileCount: sw_integer;
function  GetRunProfileName(Idx: sw_integer): string;
function  AddRunProfile(const AName, AMainFile, AParams: string): sw_integer;
procedure GetRunProfileParams(Idx: sw_integer; var AName, AMainFile, AParams: string);
procedure SetRunProfileParams(Idx: sw_integer; const AName, AMainFile, AParams: string);
procedure ClearRunProfiles;
procedure DoneRunProfiles;

{ Apply profile Idx: set primary file + run parameters from it.
  Idx out of range = clear primary + clear params. }
procedure ApplyRunProfile(Idx: sw_integer);

const
     RunProfiles : PRunProfileCollection = nil;
     ActiveRunProfile : sw_integer = -1;  { -1 = none active }

implementation

uses WUtils,
     FPVars, FPIntf;

constructor TRunProfile.Init(const AName, AMainFile, AParams: string);
begin
  inherited Init;
  Name:=nil; MainFile:=nil; Params:=nil;
  SetAll(AName, AMainFile, AParams);
end;

function TRunProfile.GetName: string;
begin
  GetName:=GetStr(Name);
end;

function TRunProfile.GetMainFile: string;
begin
  GetMainFile:=GetStr(MainFile);
end;

function TRunProfile.GetParams: string;
begin
  GetParams:=GetStr(Params);
end;

procedure TRunProfile.GetAll(var AName, AMainFile, AParams: string);
begin
  AName:=GetStr(Name);
  AMainFile:=GetStr(MainFile);
  AParams:=GetStr(Params);
end;

procedure TRunProfile.SetAll(const AName, AMainFile, AParams: string);
begin
  if Name<>nil then DisposeStr(Name); Name:=NewStr(AName);
  if MainFile<>nil then DisposeStr(MainFile); MainFile:=NewStr(AMainFile);
  if Params<>nil then DisposeStr(Params); Params:=NewStr(AParams);
end;

destructor TRunProfile.Done;
begin
  inherited Done;
  if Name<>nil then DisposeStr(Name);
  if MainFile<>nil then DisposeStr(MainFile);
  if Params<>nil then DisposeStr(Params);
end;

function TRunProfileCollection.At(Index: sw_Integer): PRunProfile;
begin
  At:=inherited At(Index);
end;

function TRunProfileListBox.GetText(Item, MaxLen: sw_integer): String;
var P: PRunProfile;
    S: string;
begin
  P:=List^.At(Item);
  S:=P^.GetName;
  if S='' then S:='(unnamed)';
  if P^.GetMainFile<>'' then
    S:=S+' ['+P^.GetMainFile+']';
  GetText:=copy(S, 1, MaxLen);
end;

procedure InitRunProfiles;
begin
  if RunProfiles<>nil then DoneRunProfiles;
  New(RunProfiles, Init(8, 8));
end;

function GetRunProfileCount: sw_integer;
begin
  if RunProfiles=nil then GetRunProfileCount:=0
  else GetRunProfileCount:=RunProfiles^.Count;
end;

function GetRunProfileName(Idx: sw_integer): string;
begin
  if (RunProfiles=nil) or (Idx<0) or (Idx>=RunProfiles^.Count) then
    GetRunProfileName:=''
  else
    GetRunProfileName:=RunProfiles^.At(Idx)^.GetName;
end;

function AddRunProfile(const AName, AMainFile, AParams: string): sw_integer;
var P: PRunProfile;
begin
  if RunProfiles=nil then InitRunProfiles;
  New(P, Init(AName, AMainFile, AParams));
  RunProfiles^.Insert(P);
  AddRunProfile:=RunProfiles^.IndexOf(P);
end;

procedure GetRunProfileParams(Idx: sw_integer; var AName, AMainFile, AParams: string);
begin
  AName:=''; AMainFile:=''; AParams:='';
  if (RunProfiles=nil) or (Idx<0) or (Idx>=RunProfiles^.Count) then Exit;
  RunProfiles^.At(Idx)^.GetAll(AName, AMainFile, AParams);
end;

procedure SetRunProfileParams(Idx: sw_integer; const AName, AMainFile, AParams: string);
begin
  if (RunProfiles=nil) or (Idx<0) or (Idx>=RunProfiles^.Count) then Exit;
  RunProfiles^.At(Idx)^.SetAll(AName, AMainFile, AParams);
end;

procedure ClearRunProfiles;
begin
  if RunProfiles<>nil then RunProfiles^.FreeAll;
  ActiveRunProfile:=-1;
end;

procedure DoneRunProfiles;
begin
  if RunProfiles<>nil then Dispose(RunProfiles, Done);
  RunProfiles:=nil;
  ActiveRunProfile:=-1;
end;

procedure ApplyRunProfile(Idx: sw_integer);
var AName, AMain, AParams: string;
begin
  if (RunProfiles=nil) or (Idx<0) or (Idx>=RunProfiles^.Count) then
    begin
      { Out-of-range => no active profile; clear primary + params. }
      PrimaryFile:='';
      PrimaryFileMain:='';
      PrimaryFileSwitches:='';
      PrimaryFilePara:='';
      SetRunParameters('');
      ActiveRunProfile:=-1;
      Exit;
    end;
  RunProfiles^.At(Idx)^.GetAll(AName, AMain, AParams);
  if AMain<>'' then
    SetPrimaryFile(AMain)
  else
    begin
      PrimaryFile:='';
      PrimaryFileMain:='';
      PrimaryFileSwitches:='';
      PrimaryFilePara:='';
    end;
  SetRunParameters(AParams);
  ActiveRunProfile:=Idx;
end;

constructor TRunProfileItemDialog.Init(AProfile: PRunProfile);
var R, R2: TRect;
begin
  R.Assign(0, 0, 60, 12);
  inherited Init(R, 'Run profile');
  Profile:=AProfile;

  GetExtent(R); R.Grow(-3, -2);
  Inc(R.A.Y); R.B.Y:=R.A.Y+1;
  New(NameIL, Init(R, 64)); Insert(NameIL);
  R2.Copy(R); R2.Move(-1, -1); Insert(New(PLabel, Init(R2, '~N~ame', NameIL)));

  R.Move(0, 3);
  New(MainIL, Init(R, 128)); Insert(MainIL);
  R2.Copy(R); R2.Move(-1, -1); Insert(New(PLabel, Init(R2, '~M~ain file', MainIL)));

  R.Move(0, 3);
  New(ParamIL, Init(R, 255)); Insert(ParamIL);
  R2.Copy(R); R2.Move(-1, -1); Insert(New(PLabel, Init(R2, '~P~arameters', ParamIL)));

  InsertButtons(@Self);
  NameIL^.Select;
end;

function TRunProfileItemDialog.Execute: Word;
var R: word;
    SN, SM, SP: string;
begin
  Profile^.GetAll(SN, SM, SP);
  NameIL^.SetData(SN); MainIL^.SetData(SM); ParamIL^.SetData(SP);
  R:=inherited Execute;
  if R=cmOK then
    begin
      NameIL^.GetData(SN); MainIL^.GetData(SM); ParamIL^.GetData(SP);
      Profile^.SetAll(SN, SM, SP);
    end;
  Execute:=R;
end;

constructor TRunProfilesDialog.Init;
var R, R2, R3: TRect;
    SB: PScrollBar;
begin
  R.Assign(0, 0, 60, 16);
  inherited Init(R, 'Run profiles');

  GetExtent(R); R.Grow(-3, -2); Inc(R.A.Y); R3.Copy(R); Dec(R.B.X, 12);
  R2.Copy(R); R2.Move(1, 0); R2.A.X:=R2.B.X-1;
  New(SB, Init(R2)); Insert(SB);
  New(ProfilesLB, Init(R, 1, SB));
  Insert(ProfilesLB);
  R2.Copy(R); R2.Move(0, -1); R2.B.Y:=R2.A.Y+1; Dec(R2.A.X);
  Insert(New(PLabel, Init(R2, '~P~rofiles', ProfilesLB)));

  R.Copy(R3); R.A.X:=R.B.X-10; R.B.Y:=R.A.Y+2;
  Insert(New(PButton, Init(R, 'O~K~', cmOK, bfNormal)));
  R.Move(0, 2);
  Insert(New(PButton, Init(R, '~E~dit', cmEditItem, bfDefault)));
  R.Move(0, 2);
  Insert(New(PButton, Init(R, '~N~ew', cmAddItem, bfNormal)));
  R.Move(0, 2);
  Insert(New(PButton, Init(R, '~D~elete', cmDeleteItem, bfNormal)));
  R.Move(0, 2);
  Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));
  SelectNext(false);
end;

procedure TRunProfilesDialog.HandleEvent(var Event: TEvent);
var DontClear: boolean;
begin
  case Event.What of
    evKeyDown :
      begin
        DontClear:=false;
        case Event.KeyCode of
          kbIns : Message(@Self, evCommand, cmAddItem, nil);
          kbDel : Message(@Self, evCommand, cmDeleteItem, nil);
        else DontClear:=true;
        end;
        if not DontClear then ClearEvent(Event);
      end;
    evBroadcast :
      case Event.Command of
        cmListItemSelected :
          if Event.InfoPtr=pointer(ProfilesLB) then
            Message(@Self, evCommand, cmEditItem, nil);
      end;
    evCommand :
      begin
        DontClear:=false;
        case Event.Command of
          cmAddItem    : Add;
          cmDeleteItem : Delete;
          cmEditItem   : Edit;
        else DontClear:=true;
        end;
        if not DontClear then ClearEvent(Event);
      end;
  end;
  inherited HandleEvent(Event);
end;

function TRunProfilesDialog.Execute: Word;
var R: word;
    C: PRunProfileCollection;
    I: integer;
    SN, SM, SP: string;
begin
  New(C, Init(8, 8));
  if RunProfiles<>nil then
    for I:=0 to RunProfiles^.Count-1 do
      begin
        RunProfiles^.At(I)^.GetAll(SN, SM, SP);
        C^.Insert(New(PRunProfile, Init(SN, SM, SP)));
      end;
  ProfilesLB^.NewList(C);
  R:=inherited Execute;
  if R=cmOK then
    begin
      if RunProfiles<>nil then Dispose(RunProfiles, Done);
      RunProfiles:=C;
      { Active index might now be out of range if profiles were removed. }
      if ActiveRunProfile>=GetRunProfileCount then
        ActiveRunProfile:=GetRunProfileCount-1;
      if ActiveRunProfile<-1 then ActiveRunProfile:=-1;
    end
  else
    Dispose(C, Done);
  Execute:=R;
end;

procedure TRunProfilesDialog.Add;
var P: PRunProfile;
begin
  if ProfilesLB^.Range>=MaxRunProfileCount then Exit;
  New(P, Init('', '', ''));
  if Application^.ExecuteDialog(New(PRunProfileItemDialog, Init(P)), nil)=cmOK then
    begin
      ProfilesLB^.List^.Insert(P);
      ProfilesLB^.SetRange(ProfilesLB^.List^.Count);
      ReDraw;
    end
  else
    Dispose(P, Done);
end;

procedure TRunProfilesDialog.Edit;
var P: PRunProfile;
begin
  if ProfilesLB^.Range=0 then Exit;
  P:=ProfilesLB^.List^.At(ProfilesLB^.Focused);
  Application^.ExecuteDialog(New(PRunProfileItemDialog, Init(P)), nil);
  ReDraw;
end;

procedure TRunProfilesDialog.Delete;
begin
  if ProfilesLB^.Range=0 then Exit;
  ProfilesLB^.List^.AtFree(ProfilesLB^.Focused);
  ProfilesLB^.SetRange(ProfilesLB^.List^.Count);
  ReDraw;
end;

end.
