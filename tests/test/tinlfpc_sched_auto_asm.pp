{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS_MIN=1 }
{
  -OoSCHEDULE auto-schedules inline asm blocks by default (the
  -OoAUTOSCHEDASM optimizer switch is on out of the box). No
  $schedule on directive is needed: any reorder-safe pair the PMMX
  scheduler can find inside the block is fair game.

  The block below is hand-crafted so the U/V reorderer has exactly
  one [P, NP, P] hoist available, mirroring the pure-asm
  tinlfpc_sched_visible_swap goalpost but inside a Pascal proc:

    movl $1, %eax    { P  -- pairable, reg-imm }
    shll $4, %edx    { NP -- shift writes flags + edx }
    movl $2, %ecx    { P  -- should hoist past the SHL }
    addl %ecx, %eax  { eax := 1 + 2 = 3 }
    movl %eax, tmp

  HasDep(SHL %edx, MOV %ecx) is clear: regs disjoint, no mem.
  CanPair(MOV %eax, MOV %ecx) is clear: both pairable, regs and
  flags disjoint. Expected: at least one `; sched-swap' marker in
  the .s -- proves the auto rule fired without {$schedule on}.

  Companion: tinlfpc_sched_inline_asm.pp covers the legacy
  -OoNOAUTOSCHEDASM path (block left untouched without the
  directive).
}
program tinlfpc_sched_auto_asm;

{$mode objfpc}
{$asmmode att}

function f: longint;
var
  tmp: longint;
begin
  asm
    movl  $1, %eax
    shll  $4, %edx
    movl  $2, %ecx
    addl  %ecx, %eax
    movl  %eax, tmp
  end;
  f := tmp;
end;

begin
  if f <> 3 then halt(1);
end.
