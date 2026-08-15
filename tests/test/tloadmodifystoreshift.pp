{ %OPT=-O2 -OoUSELOADMODIFYSTORE }

program tloadmodifystoreshift;

{$mode delphi}

type
  pWord = ^word;
  tBits = object
    pos: integer;
    buffer: dword;
    procedure consumeBits(bits: integer); inline;
    function readRice0: word; inline;
    function readBits(bits: byte): word; inline;
    procedure readValues(pData: pWord; n: dword; bits: byte); inline;
    procedure readAuto(pData: pWord; n: dword; modeMask: byte);
  end;

procedure tBits.consumeBits(bits: integer);
begin
  buffer := buffer shr bits;
  pos := pos - bits;
end;

function tBits.readRice0: word;
begin
  result := 0;
  while (buffer and 1) <> 0 do begin
    inc(result);
    consumeBits(1);
  end;
  consumeBits(1);
end;

function tBits.readBits(bits: byte): word;
begin
  result := buffer and ((1 shl bits) - 1);
  buffer := buffer shr bits;
  pos := pos - bits;
end;

procedure tBits.readValues(pData: pWord; n: dword; bits: byte);
var
  i: integer;
begin
  case bits of
    0: ;
    1: for i := 0 to n - 1 do begin pData^ := readBits(1); inc(pData); end;
    2: for i := 0 to n - 1 do begin pData^ := readBits(2); inc(pData); end;
    4: for i := 0 to n - 1 do begin pData^ := readBits(4); inc(pData); end;
    8: for i := 0 to n - 1 do begin pData^ := readBits(8); inc(pData); end;
    else for i := 0 to n - 1 do begin pData^ := readBits(bits); inc(pData); end;
  end;
end;

procedure tBits.readAuto(pData: pWord; n: dword; modeMask: byte);
var
  mode, packedWidth: byte;
begin
  mode := readRice0;
  if (modeMask and (1 shl mode)) = 0 then
    halt(10);
  case mode of
    0: pData^ := readRice0;
    1: fillword(pData^, n, 0);
    2: readValues(pData, n, readRice0);
    3: begin
      packedWidth := readRice0;
      readValues(pData, n, packedWidth);
    end;
  end;
end;

var
  state: tBits;
  value: word;

begin
  state.pos := 29;
  state.buffer := 22853623;
  state.readAuto(@value, 1, 15);
  if value <> 75 then
    halt(1);
  if state.buffer <> 43 then
    halt(2);
  if state.pos <> 10 then
    halt(3);
end.
