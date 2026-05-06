{
  Helper unit for tinlfpc_default_param_asm_xunit. Exposes an asm-inline
  function with a default-valued parameter so the inlininginfo body
  round-trips through the .ppu before the consumer splices it. This is
  the path the original uuchar.pp/system.ppu PPU writer crash hit.
}
unit udefparam;

{$mode objfpc}
{$INLINE ON}
{$asmmode intel}

interface

function add_def(x: longint; y: longint = 5): longint; assembler; inline;

implementation

function add_def(x: longint; y: longint = 5): longint; assembler; nostackframe; inline;
asm
  mov eax, x
  add eax, y
end;

end.
