{ %OPT=-O3 -CpPENTIUMMMX -OpPENTIUM }
{ %CPU=i386 }
program trepeatedloadlifetime;
{$mode delphi}
{$asmmode intel}
{$inline on}
type
  TRow = record Lo, Hi: LongInt; end;
  TBox = class
    X, Y, LastX, LastY: LongInt;
    Rows: array of TRow;
    function Track: Boolean;
  end;
function LowOf(A, B: LongInt): LongInt; inline;
begin if A < B then Result := A else Result := B; end;
function HighOf(A, B: LongInt): LongInt; inline;
begin if A > B then Result := A else Result := B; end;
function TBox.Track: Boolean;
var I, Count, V: LongInt; Moved: Boolean;
begin
  Moved := (X <> LastX) or (Y <> LastY);
  Count := Length(Rows);
  V := X + Y;
  for I := 0 to Count-1 do begin
    Rows[I].Lo := LowOf(V, Rows[I].Lo);
    Rows[I].Hi := HighOf(V, Rows[I].Hi);
  end;
  if Moved then SetLength(Rows, Length(Rows)+1);
  Result := Moved;
end;
var B: TBox; I: LongInt;
begin
  B := TBox.Create;
  SetLength(B.Rows, 16);
  B.X := 7; B.Y := 9; B.LastX := 7; B.LastY := 9;
  asm xor edx,edx end ['edx'];
  if B.Track then Halt(1);
  B.LastX := 8;
  if not B.Track then Halt(2);
  B.Free;
  WriteLn('register lifetime passed');
end.
