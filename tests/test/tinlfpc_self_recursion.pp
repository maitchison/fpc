{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{ Direct self-recursive inline procedure. Before the cnf_inline_blocked_self
  guard, the flat per-site budget on `working` had no depth-decay, so
  pass1_inline spliced the body unboundedly and the compiler crashed
  (page-fault on go32v2, AV / stack overflow on win32 host). With the guard,
  the outer call inlines once and the recursive call inside the splice
  degrades to a plain CALL, terminating recursion naturally.

  Encoded as the same shape uBits.consumeBits had: a guarded recursive
  branch (long-consume case) plus a non-recursive fast path. }
program tinlfpc_self_recursion;

{$mode objfpc}
{$inline on}

var
  hits: longint;

procedure consume(bits: longint); inline;
begin
  inc(hits);
  if bits = 0 then exit;
  if bits > 16 then begin
    consume(bits and $f);
    exit;
  end;
end;

begin
  hits := 0;
  consume(50);
  if hits <> 2 then halt(1);
  hits := 0;
  consume(0);
  if hits <> 1 then halt(2);
  hits := 0;
  consume(8);
  if hits <> 1 then halt(3);
  halt(0);
end.
