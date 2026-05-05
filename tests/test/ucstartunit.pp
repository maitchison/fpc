{
  Companion unit for tinlfpc_cstart_xunit -- mirrors dev/shared/uTimer.pas.
  Cross-unit asm-inline of cStart used to crash the compiler with
  SIGSEGV / undefined-symbol errors because the body's tasmsymbol pointers
  (e.g. `lea edi, cycleTimer`) are not PPU-serialised: same-unit inlining
  works because current_asmdata persists, but cross-unit the providing
  unit's asmdata is freed before the consumer splices, leaving dangling
  pointers in the inlined operand. The fix in compiler/ncal.pas's
  check_inlining now rejects cross-unit asm-inline with a clear
  diagnostic and falls back to a normal CALL.
}
unit ucstartunit;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

interface

const
  CYCLE_TIMER_LOG2_SIZE = 5;

type
  tCycleTimer = record
    startTime, stopTime: uint64;
    sumTime, n: int64;
  end;

var
  cycleTimer: array[0..15] of tCycleTimer;

procedure cStart(slot: longint); register; assembler; inline;

implementation

procedure cStart(slot: longint); register; nostackframe; assembler; inline;
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

end.
