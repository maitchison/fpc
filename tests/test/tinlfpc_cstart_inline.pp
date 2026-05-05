{ %OPT=-OoINLINESITEBUDGET=1000 -Si }
{ %RESULT=0 }
{
  Realistic regression for the cStart RDTSC helper from
  X:\utimer.pas / dev\shared\uTimer.pas. cStart's body is a normal asm
  idiom: param arrives in EAX (default register cc on i386), copy to a
  scratch reg before RDTSC clobbers EAX, scale the slot index, store
  the cycle count into the cycleTimer slot.

  Pre-fix this body was rejected by asmnode_inline_safe -- the asm
  reader emits `mov ebx, slot` as a top_local operand (because the
  destination register isn't slot's home register), and top_local was
  NOT on the splice whitelist. The proc was callable normally, so
  runtime worked, but every call site emitted a CALL.

  Post-fix (compiler/nbas.pas + compiler/psub.pas):
    * inline_asm_top_local_is_register_param accepts top_local of a
      parameter whose calleeside paraloc is a single integer register
      (predicate in nbas.pas).
    * asmnode_inline_safe (psub.pas) now accepts that operand kind.
    * inline_resolve_asm_paralocals (nbas.pas) rewrites each accepted
      top_local to top_reg of the param's home register at splice time,
      after inline_clone_asm_labels and before codegen sees the body.
    * The v2(c) loader in ncal.pas already places the param's value in
      its home register before the spliced body runs, so the rewrite
      is semantically a no-op shift in operand kind.

  Verify the splice with -al -an: tinlfpc_cstart_inline.s should
  contain `rdtsc` once per call site in main and zero `call P$..._
  $$_CSTART$LONGINT` references. -vd should not emit any "Inline
  disabled for cStart" or "Not inlining cStart" lines. }
program tinlfpc_cstart_inline;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

const
  CYCLE_TIMER_LOG2_SIZE = 5;

type
  tCycleTimer = record
    startTime, stopTime: uint64;
    sumTime, n: int64;
  end;

var
  cycleTimer: array[0..15] of tCycleTimer;

procedure cStart(slot: longint); assembler; nostackframe; inline;
asm
  push ebx
  push edx
  push edi

  mov  ebx, slot
  rdtsc

  shl  ebx, CYCLE_TIMER_LOG2_SIZE
  lea  edi, cycleTimer
  add  edi, ebx
  mov  [edi], eax
  mov  [edi+4], edx

  pop  edi
  pop  edx
  pop  ebx
end;

var
  t0, t1: uint64;
begin
  fillchar(cycleTimer, sizeof(cycleTimer), 0);
  cStart(0);
  t0 := cycleTimer[0].startTime;
  cStart(0);
  t1 := cycleTimer[0].startTime;
  if t1 < t0 then halt(1);
  if (t0 = 0) and (t1 = 0) then halt(2);
end.
