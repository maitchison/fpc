{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS=0 }
{
  Path A / A3 churn-guard, post-cascade-fix.

  Verifies that AlreadyPairsWithNext inside TryHoistBackward continues
  to reject hoists that would just shuffle which adjacency carries a
  U/V pair without creating a new one.

  The body below has TWO trivially-paired regions:

    mov ecx, 1         ; four reg-imm moves, no shared regs, no flags
    mov edx, 2         ;  -> every adjacent (M,M) is a legal U/V pair
    mov esi, 3         ;     by linear order alone.
    mov edi, 4         ;
    lea eax, [ecx+edx] ; three lea-chained loads, every adjacent pair
    lea eax, [eax+esi] ; shares eax -> never pair, and there is no
    lea eax, [eax+edi] ; room to hoist a lea past the mov edx/esi/edi
                       ; (lea reads ecx/edx/esi/edi; mov edx writes
                       ;  edx; shared reg blocks reorder).

  No interleaving between the two regions is possible (the first lea
  reads ecx + edx, blocking any motion past those movs), and within
  each region the linear order is already optimal -- so the cascade
  fixpoint completes at zero swaps. AlreadyPairsWithNext is what
  rejects the (mov edx -> lea hoist) attempt that the relaxed top-level
  gate now allows.

  Returns 1 + 2 + 3 + 4 = 10 regardless of input.
}
program tinlfpc_sched_no_churn;

{$asmmode intel}

function already_paired: longint; assembler; nostackframe; schedule;
asm
  mov ecx, 1
  mov edx, 2
  mov esi, 3
  mov edi, 4
  lea eax, [ecx + edx]
  lea eax, [eax + esi]
  lea eax, [eax + edi]
end;

begin
  if already_paired <> 10 then halt(1);
  if already_paired <> 10 then halt(2);
end.
