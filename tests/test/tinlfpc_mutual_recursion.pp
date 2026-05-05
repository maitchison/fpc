{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{ Indirect mutual-recursive inline procedures: a -> b -> c -> a.

  The cnf_inline_blocked_self guard only catches direct self-calls
  (current_procinfo.procdef = procdefinition). For an indirect cycle
  whose outermost host is unrelated -- here `main` calling `a`, with
  the cycle living entirely in a/b/c -- the direct-self check never
  fires and the flat per-site SITEBUDGET has no depth penalty, so
  pass1_inline + firstpass(inlineblock) used to recurse forever and
  the compiler hung.

  inline_splice_chain (in ncal.pas implementation) tracks procdefs
  currently being spliced. check_inlining now refuses to inline a
  callee that's already on the chain. The outer chain a->b->c
  inlines normally; only the recursive c->a call (which would close
  the cycle) degrades to a plain CALL. Recursion terminates at
  runtime via the n<=0 guard.

  Test passes if it COMPILES at all (no compiler hang, no stack
  overflow) and produces the right runtime hit count. Runtime
  semantics: each call increments hits and recurses with n-1 unless
  n<=0. a(6) -> b(5) -> c(4) -> a(3) -> b(2) -> c(1) -> a(0)
  = 7 hits. }
program tinlfpc_mutual_recursion;

{$mode objfpc}
{$inline on}

var
  hits: longint;

procedure b(n: longint); forward;
procedure c(n: longint); forward;

procedure a(n: longint); inline;
begin
  inc(hits);
  if n <= 0 then exit;
  b(n - 1);
end;

procedure b(n: longint); inline;
begin
  inc(hits);
  if n <= 0 then exit;
  c(n - 1);
end;

procedure c(n: longint); inline;
begin
  inc(hits);
  if n <= 0 then exit;
  a(n - 1);
end;

begin
  hits := 0;
  a(6);
  if hits <> 7 then halt(1);
  hits := 0;
  a(0);
  if hits <> 1 then halt(2);
  hits := 0;
  c(2);
  if hits <> 3 then halt(3);
  halt(0);
end.
