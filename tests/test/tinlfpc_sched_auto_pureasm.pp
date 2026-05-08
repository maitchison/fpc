{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS_MIN=1 }
{
  Auto-on rule for pure-asm procs: -OoSCHEDULE alone (without the
  `schedule' proc modifier) is enough to put the i386 PMMX scheduler
  over a pi_is_assembler proc when the default -OoAUTOSCHEDASM
  optimizer switch is on. -OoNOAUTOSCHEDASM falls back to the legacy
  modifier-only path -- see tinlfpc_sched_modifier.

  Same hand-crafted [P, NP, P] hoist as tinlfpc_sched_visible_swap;
  the only difference is that `schedule' is dropped from the proc
  declaration, so the scheduler runs only because the auto rule
  fires. Expected: at least one `; sched-swap' marker in the .s.
}
program tinlfpc_sched_auto_pureasm;

{$mode objfpc}
{$asmmode att}

function f: longint; assembler; nostackframe;
asm
  movl  $1, %eax     { P }
  shll  $4, %edx     { NP }
  movl  $2, %ecx     { P -- should hoist past SHL }
  addl  %ecx, %eax   { eax := 1 + 2 = 3 }
end;

begin
  if f <> 3 then halt(1);
end.
