{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS=1 }
{
  Visibility limit test: a hand-crafted [P, NP, P] sequence in a
  pure-asm proc (so compiler-side codegen drift cannot move the
  goalposts). With v1's pairable opcode set, the third MOV should
  hoist past the SHL exactly once -- one `; sched-swap` marker in
  the resulting .s.

  This test depends on the visibility infrastructure shipped with
  feature/sched-visibility:
    * compiler/i386/schedi386.pas drops a tai_comment 'sched-swap'
      at the swap site
    * scripts/test-lite.ps1 honours %SCHED_SWAPS=N

  Hazard analysis (mirrors HasDep in schedi386.pas):
    i1 = movl $1, %eax    (P; reg-imm; no flags; no mem)
    i2 = shll $4, %edx    (NP; flag-write; no mem)
    i3 = movl $2, %ecx    (P; reg-imm; no flags; no mem)

  CanPair(i1,i3): both pairable; mem disjoint (neither); flags
    disjoint; regs disjoint (eax vs ecx). -> can pair.
  HasDep(i2,i3): mem disjoint; i2 flag-writes but i3 ignores flags;
    regs disjoint (edx vs ecx). -> can hop past.

  After the swap the asm becomes
    movl $1, %eax
    movl $2, %ecx
    shll $4, %edx
    addl %ecx, %eax
  so eax = 1 + 2 = 3 at return.

  When Path A lands the U/V/UV class table, the existing
  `tinlfpc_sched_arith` and the other sched_* tests still need to
  stay at 0 swaps; this is the single-positive-control case.
}
program tinlfpc_sched_visible_swap;

{$mode objfpc}
{$asmmode att}

function f: longint; assembler; nostackframe; schedule;
asm
  movl  $1, %eax     { P }
  shll  $4, %edx     { NP }
  movl  $2, %ecx     { P -- should hoist past SHL }
  addl  %ecx, %eax   { eax := 1 + 2 = 3 }
end;

begin
  if f <> 3 then halt(1);
end.
