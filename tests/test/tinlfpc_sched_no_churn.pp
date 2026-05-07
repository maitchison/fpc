{ %OPT=-OoSCHEDULE -OpPENTIUMMMX -O2 -Si }
{ %RESULT=0 }
{ %SCHED_SWAPS=0 }
{
  Path A / A3 churn-guard.

  The scheduler must not move pairable instructions when they are
  ALREADY adjacent to a pairable, independent neighbour. Path A's
  AlreadyPairsWithNext check catches this: a hoist that just
  shuffles which UV+UV pair currently issues is a no-op cycle-wise
  but adds real .s churn (and confuses anyone reading -vd output).

  The body below is a sequence of pairwise-independent UV ops on
  distinct registers -- every adjacent pair already forms a legal
  U/V pair, so the swap count must be exactly zero.
}
program tinlfpc_sched_no_churn;

{$asmmode intel}

function already_paired(a: longint): longint; assembler; nostackframe; schedule;
asm
  mov ecx, eax              { ecx = a                                }
  mov edx, eax              { edx = a    (independent of prev)       }
  mov esi, eax              { esi = a    (independent of prev)       }
  mov edi, eax              { edi = a    (independent of prev)       }
  add ecx, 1                { ecx += 1   (depends on prev `mov ecx`,
                              but pairs vs `mov edx` etc -- the prev
                              ELIGIBLE neighbour `mov edi, eax` has
                              no dep with this `add ecx`)            }
  add edx, 2                { edx += 2                               }
  add esi, 3                { esi += 3                               }
  add edi, 4                { edi += 4                               }
  lea eax, [ecx + edx]      { eax = a+1 + a+2 = 2a+3                 }
  lea eax, [eax + esi - 3]  { eax += a+3 - 3 = a; total 3a+3         }
  lea eax, [eax + edi - 4]  { eax += a+4 - 4 = a; total 4a+3         }
end;

begin
  if already_paired(0) <> 3       then halt(1);
  if already_paired(1) <> 4*1 + 3 then halt(2);
  if already_paired(5) <> 4*5 + 3 then halt(3);
  if already_paired(9) <> 4*9 + 3 then halt(4);
end.
