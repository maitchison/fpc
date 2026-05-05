{ %OPT=-O3 -OoINLINESITEBUDGET=1000 -CpPENTIUMMMX -OpPENTIUMMMX -Si }
{ %RESULT=0 }
{
  Regression: dev/shared/uUtils.pas zagZig is `function zagZig(y: dword):
  int32; inline; register;` with an asm body but no `assembler;` modifier.
  When the user adds `assembler;` (still without `nostackframe`), the
  asm-inline gate must reject cleanly via pio_inline_not_possible -- not
  crash. Adding `assembler` puts the proc on the asm-inline gate path
  (po_assembler set), and is_assembler_inlineable now reads
  funcretloc[calleeside] / paraloc[calleeside]; those are calleeside
  paralocs, which the gate now init_paraloc_info's before reading so a
  zero-initialised record can't be confused with a real "single-intreg"
  result.

  Mirrors the actual uUtils.pas zagZig: {$MODE DELPHI}, Intel asm default,
  int32 result, manual ebx save/restore.
}
program tinlfpc_zagzig;

{$MODE DELPHI}
{$INLINE ON}

type
  int32 = longint;

function zagZig(y: dword): int32; assembler; nostackframe; inline;
asm
  push ebx
  mov ebx, eax
  shr eax, 1
  and ebx, $1
  neg ebx
  xor eax, ebx
  pop ebx
end;

var
  r: int32;
begin
  r := zagZig(0);
  if r <> 0 then halt(1);
  r := zagZig(1);
  if r <> -1 then halt(2);
  r := zagZig(2);
  if r <> 1 then halt(3);
  r := zagZig(3);
  if r <> -2 then halt(4);
  r := zagZig(4);
  if r <> 2 then halt(5);
end.
