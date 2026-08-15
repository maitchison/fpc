{ %OPT=-O3 }

program toptimizerscope1;

{$mode objfpc}
{$optimization ORDERFIELDS}

type
  tBefore = class
    a: byte;
    b: dword;
    c: byte;
  end;

{$push}
{$optimization OFF}
type
  tOff = class
    a: byte;
    b: dword;
    c: byte;
  end;
{$pop}

type
  tRestored = class
    a: byte;
    b: dword;
    c: byte;
  end;

{$push}
{$optimization ON, LEVEL2}
type
  tLevel2 = class
    a: byte;
    b: dword;
    c: byte;
  end;
{$pop}

type
  tRestoredAgain = class
    a: byte;
    b: dword;
    c: byte;
  end;

begin
  if tBefore.InstanceSize <> 12 then
    halt(1);
  if tOff.InstanceSize <> 16 then
    halt(2);
  if tRestored.InstanceSize <> 12 then
    halt(3);
  if tLevel2.InstanceSize <> 16 then
    halt(4);
  if tRestoredAgain.InstanceSize <> 12 then
    halt(5);
end.
