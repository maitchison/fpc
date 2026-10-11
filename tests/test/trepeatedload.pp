{ %OPT=-O3 -CpPENTIUMMMX -OpPENTIUM }
{ %CPU=i386 }
program trepeatedload;
{$mode delphi}
{$inline on}
type
  TRow = record Lo, Hi: LongInt; end;
  TRows = array of TRow;
  TFixed = array[0..15] of TRow;
  PFixed = ^TFixed;
  TBox = class
    Rows: TRows;
    Raw: PFixed;
    Fixed: TFixed;
    function SumRows(Count: LongInt): LongInt;
    function SumFixed(Count: LongInt): LongInt;
    procedure ClampRows(Count, X: LongInt);
    procedure ClampFixed(Count, X: LongInt);
    procedure ClampRaw(Count, X: LongInt);
  end;
function LowOf(A, B: LongInt): LongInt; inline;
begin if A < B then Result := A else Result := B; end;
function HighOf(A, B: LongInt): LongInt; inline;
begin if A > B then Result := A else Result := B; end;
function TBox.SumRows(Count: LongInt): LongInt;
var I: LongInt;
begin
  Result := 0;
  for I := 0 to Count-1 do Inc(Result, Rows[I].Lo);
end;
function TBox.SumFixed(Count: LongInt): LongInt;
var I: LongInt;
begin
  Result := 0;
  for I := 0 to Count-1 do Inc(Result, Fixed[I].Lo);
end;
procedure TBox.ClampRows(Count, X: LongInt);
var I: LongInt;
begin
  for I := 0 to Count-1 do begin
    Rows[I].Lo := LowOf(X, Rows[I].Lo);
    Rows[I].Hi := HighOf(X, Rows[I].Hi);
  end;
end;
procedure TBox.ClampRaw(Count, X: LongInt);
var I: LongInt;
begin
  for I := 0 to Count-1 do begin
    Raw^[I].Lo := LowOf(X, Raw^[I].Lo);
    Raw^[I].Hi := HighOf(X, Raw^[I].Hi);
  end;
end;
procedure TBox.ClampFixed(Count, X: LongInt);
var I: LongInt;
begin
  for I := 0 to Count-1 do begin
    Fixed[I].Lo := LowOf(X, Fixed[I].Lo);
    Fixed[I].Hi := HighOf(X, Fixed[I].Hi);
  end;
end;
function AliasedStore(P, Q: PLongInt): LongInt;
var A: LongInt;
begin A := P^; Q^ := A + 1; Result := A + P^; end;
function ByteStore(P: PLongInt): LongInt;
var A: LongInt;
begin A := P^; PByte(P)^ := 9; Result := A + P^; end;
function Walk(P: PLongInt): LongInt;
var A: LongInt;
begin A := P^; Inc(P); Result := A + P^; end;
procedure Change(P: PLongInt);
begin Inc(P^); end;
function AcrossCall(P: PLongInt): LongInt;
var A: LongInt;
begin A := P^; Change(P); Result := A + P^; end;
function ReadVolatile(P: PLongInt): LongInt;
begin Result := Volatile(P^) + Volatile(P^); end;
var B: TBox; I: LongInt; V: array[0..1] of LongInt;
begin
  B := nil;
  if B.SumRows(0) <> 0 then Halt(1);
  if B.SumFixed(0) <> 0 then Halt(2);
  B := TBox.Create;
  SetLength(B.Rows, 16);
  GetMem(B.Raw, SizeOf(TFixed));
  for I := 0 to 15 do begin
    B.Rows[I].Lo := I;
    B.Rows[I].Hi := I;
    B.Fixed[I] := B.Rows[I];
    B.Raw^[I] := B.Rows[I];
  end;
  if B.SumRows(16) <> 120 then Halt(3);
  if B.SumFixed(16) <> 120 then Halt(4);
  B.ClampRows(16, 7);
  B.ClampFixed(16, 7);
  B.ClampRaw(16, 7);
  for I := 0 to 15 do begin
    if B.Rows[I].Lo <> LowOf(I,7) then Halt(5);
    if B.Rows[I].Hi <> HighOf(I,7) then Halt(6);
    if B.Fixed[I].Lo <> B.Rows[I].Lo then Halt(7);
    if B.Fixed[I].Hi <> B.Rows[I].Hi then Halt(8);
    if B.Raw^[I].Lo <> B.Rows[I].Lo then Halt(16);
    if B.Raw^[I].Hi <> B.Rows[I].Hi then Halt(17);
  end;
  FreeMem(B.Raw);
  B.Free;
  V[0] := 3; V[1] := 7;
  if AliasedStore(@V[0], @V[0]) <> 7 then Halt(9);
  if AliasedStore(@V[0], @V[1]) <> 8 then Halt(10);
  if V[1] <> 5 then Halt(11);
  if ByteStore(@V[0]) <> 13 then Halt(12);
  if Walk(@V[0]) <> 14 then Halt(13);
  if AcrossCall(@V[0]) <> 19 then Halt(14);
  if ReadVolatile(@V[0]) <> 20 then Halt(15);
  WriteLn('repeated load cases passed');
end.
