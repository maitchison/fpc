{ %OPT=-Si }
{ %RESULT=0 }
{
  Both `managed packed record' and `packed managed record' must parse to the
  same shape. Check both spellings produce defaults that fire.
}
program tinlfpc_rfd_packed_orderings;

{$mode objfpc}{$modeswitch advancedrecords}

type
  tA = managed packed record
    x: integer = 11;
  end;
  tB = packed managed record
    y: integer = 22;
  end;

var
  a: tA;
  b: tB;
begin
  if a.x <> 11 then halt(1);
  if b.y <> 22 then halt(2);
  halt(0);
end.
