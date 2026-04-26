{
    This file is part of the Free Pascal Integrated Development Environment

    Cursor-position navigation stack for back/forward jumps inside the
    source editor. Every Go-to-Definition, error-message jump, or
    symbol-finder selection pushes the prior position; Alt+Left walks
    back through that history, Alt+Right walks forward again.

    Standard two-list (web browser style) model:
      Push(P)  : appends P to BackList; clears ForwardList.
                 Call this BEFORE any jump, with the position you're
                 about to leave.
      GoBack   : pops top of BackList, pushes current position onto
                 ForwardList, jumps to the popped entry.
      GoForward: symmetric.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
unit FPNavStk;

{$H-}

interface

uses
  Objects;

const
  NavStackCapacity = 64;

type
  TNavEntry = record
    FileName : string;     { absolute path, original case }
    X, Y     : sw_integer; { 0-based, like editor CurPos }
  end;

procedure NavStackPush(const FileName: string; X, Y: sw_integer);

function NavStackBack(const CurFile: string; CurX, CurY: sw_integer): boolean;
{ Pops one entry off BackList, pushes (CurFile,CurX,CurY) onto ForwardList,
  jumps to the popped entry. Returns true on success. }

function NavStackForward(const CurFile: string; CurX, CurY: sw_integer): boolean;

function NavStackHasBack: boolean;
function NavStackHasForward: boolean;

procedure NavStackClear;

implementation

uses
  FPViews;

type
  TRing = record
    Items : array[0..NavStackCapacity-1] of TNavEntry;
    Count : sw_integer;   { 0..NavStackCapacity }
  end;

var
  Backward, Forward_: TRing;

procedure RingClear(var R: TRing);
var i: sw_integer;
begin
  for i:=0 to NavStackCapacity-1 do
    R.Items[i].FileName:='';
  R.Count:=0;
end;

procedure RingPush(var R: TRing; const E: TNavEntry);
var i: sw_integer;
begin
  if E.FileName='' then exit;
  { Coalesce: if pushing the same place twice in a row, don't grow. }
  if (R.Count>0) and
     (R.Items[R.Count-1].FileName=E.FileName) and
     (R.Items[R.Count-1].X=E.X) and
     (R.Items[R.Count-1].Y=E.Y) then exit;
  if R.Count>=NavStackCapacity then
    begin
      { Drop oldest. }
      for i:=0 to NavStackCapacity-2 do
        R.Items[i]:=R.Items[i+1];
      Dec(R.Count);
    end;
  R.Items[R.Count]:=E;
  Inc(R.Count);
end;

function RingPop(var R: TRing; var E: TNavEntry): boolean;
begin
  RingPop:=false;
  if R.Count<=0 then exit;
  Dec(R.Count);
  E:=R.Items[R.Count];
  R.Items[R.Count].FileName:='';
  RingPop:=true;
end;

function MakeEntry(const FileName: string; X, Y: sw_integer): TNavEntry;
begin
  MakeEntry.FileName:=FileName;
  MakeEntry.X:=X;
  MakeEntry.Y:=Y;
end;

procedure NavStackPush(const FileName: string; X, Y: sw_integer);
begin
  RingPush(Backward, MakeEntry(FileName, X, Y));
  RingClear(Forward_);
end;

function JumpTo(const E: TNavEntry): boolean;
var W: PSourceWindow;
begin
  W:=TryToOpenFile(nil, E.FileName, E.X, E.Y, true);
  if Assigned(W) then W^.Select;
  JumpTo:=Assigned(W);
end;

function NavStackHasBack: boolean;
begin
  NavStackHasBack:=Backward.Count>0;
end;

function NavStackHasForward: boolean;
begin
  NavStackHasForward:=Forward_.Count>0;
end;

function NavStackBack(const CurFile: string; CurX, CurY: sw_integer): boolean;
var Target: TNavEntry;
begin
  NavStackBack:=false;
  if not RingPop(Backward, Target) then exit;
  if CurFile<>'' then RingPush(Forward_, MakeEntry(CurFile, CurX, CurY));
  NavStackBack:=JumpTo(Target);
end;

function NavStackForward(const CurFile: string; CurX, CurY: sw_integer): boolean;
var Target: TNavEntry;
begin
  NavStackForward:=false;
  if not RingPop(Forward_, Target) then exit;
  if CurFile<>'' then RingPush(Backward, MakeEntry(CurFile, CurX, CurY));
  NavStackForward:=JumpTo(Target);
end;

procedure NavStackClear;
begin
  RingClear(Backward);
  RingClear(Forward_);
end;

initialization
  NavStackClear;

end.
