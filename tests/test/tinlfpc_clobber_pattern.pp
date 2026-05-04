{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{
  Regression / hazard test: in `assembler; nostackframe; register; inline;`
  procs the FPC asm reader resolves a Pascal param name (e.g. `slot`) to
  its ABI register location (EAX for the first int param). If the asm
  body clobbers EAX before reading `slot`, the read returns the clobbered
  value -- a classic register-clobber-before-read bug that's invisible
  in non-inlined builds where the prologue spills paras to the stack.

  This test demonstrates the CORRECT pattern: read param BEFORE clobbering
  its register. If the inliner ever changes how para registers are bound
  (e.g. uses a temp instead of the ABI register), this test catches the
  regression because the value comes back wrong.

  Original symptom (vplay's cStart): write to wild address -> runtime 216.
  Bug source: dev/video/uTimer.pas:cStart -- push eax; rdtsc; mov ebx, slot
  reads the trashed timestamp instead of slot.
}
program tinlfpc_clobber_pattern;

{$INLINE ON}
{$asmmode intel}

var
  output: array[0..7] of longint;

{ Correct ordering: read slot (in EAX) BEFORE clobbering EAX. }
procedure write_at(slot: longint); assembler; nostackframe; inline;
asm
  push ebx
  push edi

  mov ebx, slot          { read slot first; slot is in EAX }
  shl ebx, 2             { byte offset = slot * 4 }

  rdtsc                  { now safe to clobber EAX/EDX }
  mov edi, offset output
  add edi, ebx
  mov [edi], eax         { write the timestamp's low dword }

  pop edi
  pop ebx
end;

var
  i: longint;
  hits: longint = 0;
begin
  for i := 0 to 7 do output[i] := 0;
  for i := 0 to 7 do write_at(i);
  { Each slot should have been written to (a non-zero rdtsc value).
    If the param register were clobbered before the read, all writes
    would land in the same wild slot and most output[] would stay 0. }
  for i := 0 to 7 do
    if output[i] <> 0 then inc(hits);
  if hits <> 8 then halt(1);
end.
