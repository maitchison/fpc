{
  Companion unit for tinlfpc_asm_inline_dfa_xunit. Provides pure-asm
  inline helpers across a unit boundary so the consumer's call sites
  go through the cross-unit splice path -- which is where the
  asmnf_inline_splice flag actually matters.

  In the same-unit case, getcopy preserves tnf_pass1_done on the
  spliced asmnode and firstpass skips pass_typecheck on the clone,
  so pi_has_assembler_block never gets set on the caller anyway.
  In the cross-unit case, the callee's body is loaded from .ppu via
  ppuload, which restores `flags` but NOT transientflags -- so
  tnf_pass1_done is clear on the loaded clone, firstpass runs
  pass_typecheck on it, and pre-fix that set pi_has_assembler_block
  on the caller's procinfo, killing DFA on the entire caller.

  asmnf_inline_splice is the bypass: pass_typecheck checks for it and
  leaves pi_has_assembler_block clear when the asmnode is a spliced
  inline-asm body, regardless of whether it came from same-unit
  getcopy or cross-unit ppuload.
}
unit udfaunit;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

interface

function add3(a, b, c: longint): longint; assembler; inline;
function shift1(x: longint): longint; assembler; inline;

implementation

function add3(a, b, c: longint): longint; assembler; nostackframe; inline;
asm
  add eax, edx
  add eax, ecx
end;

function shift1(x: longint): longint; assembler; nostackframe; inline;
asm
  shl eax, 1
end;

end.
