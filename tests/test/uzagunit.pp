{
  Cross-unit zagZig regression. Body declared `assembler; inline;` with NO
  `nostackframe;` -- exactly what the user gets by typing `assembler` onto
  the existing dev/shared/uUtils.pas zagZig. The asm-inline gate must
  reject without crashing; the call site falls back to a regular CALL.
}
unit uzagunit;

{$MODE DELPHI}
{$INLINE ON}

interface

type
  int32 = longint;

function zagZig(y: dword): int32;

implementation

function zagZig(y: dword): int32; assembler; inline;
asm
  push ebx
  mov ebx, eax
  shr eax, 1
  and ebx, $1
  neg ebx
  xor eax, ebx
  pop ebx
end;

end.
