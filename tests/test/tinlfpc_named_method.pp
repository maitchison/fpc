{ %OPT=-Si -OoNAMEDARGS }
{ %RESULT=0 }
{
  Method call site: named-arg parsing must work for object methods, not
  just free procedures. Exercises the pexpr.pas:1219 callsite.
}
program tinlfpc_named_method;

{$mode objfpc}

type
  tfoo = class
    function bar(x, y, z: longint): longint;
  end;

function tfoo.bar(x, y, z: longint): longint;
begin
  result := x*100 + y*10 + z;
end;

var
  o: tfoo;
  r: longint;
begin
  o := tfoo.create;
  r := o.bar(1, z := 3, y := 2);
  if r <> 123 then halt(1);
  r := o.bar(z := 3, x := 1, y := 2);
  if r <> 123 then halt(2);
  o.free;
end.
