{ %OPT=-Sg }
{ %RESULT=0 }
{
  feature/codegen-proc smoke test #1 -- byte + longint codegen params
  used as instruction immediates.

  Verifies the asm reader recognises codegen-param idents in
  immediate operand position, encodes the instruction with a
  size-tagged placeholder, and emits a `cg_<paramname>:' label
  AFTER the instruction. The preprocessor's auto-injected prologue
  patches the imm bytes via `(PType(@cg_p) - 1)^' on each
  changed-value call.

  Math: shl_add(a, b, c, d) = (a shl c) * d + b
}
program tinlfpc_codegen_imm;

{$asmmode intel}

{ codegen-proc requires writable code pages -- the prologue patches
  the encoded instruction's imm bytes at runtime. Win32 (and any
  modern OS with W^X) GPFs on the patch write. The feature targets
  go32v2 / DOS where code pages are RW by default. Other targets:
  pass-through halt(0) so test-lite reports OK. }
{$ifndef GO32V2}
begin
    halt(0);
end.
{$else}

function shl_add(a, b: longint; c: byte codegen; d: longint codegen): longint;
begin
    asm
        mov   eax, a
        shl   eax, c       // codegen byte -> imm8 patch site
        imul  eax, eax, d  // codegen longint -> imm32 patch site
        add   eax, b
    end;
end;

procedure check(label_text: shortstring; got, want: longint);
begin
    if got <> want then
    begin
        writeln('FAIL: ', label_text, ' got ', got, ' want ', want);
        halt(1);
    end;
end;

begin
    { c=2, d=3 (first call: both patched) }
    check('shl_add(5,7,2,3)',  shl_add(5, 7, 2, 3),   67);
    { c=2, d=3 unchanged: cache hit, no patch }
    check('shl_add(1,1,2,3)',  shl_add(1, 1, 2, 3),   13);
    { c changed to 4, d still 3: only c patched }
    check('shl_add(5,7,4,3)',  shl_add(5, 7, 4, 3),  247);
    { c still 4, d changed to 5: only d patched }
    check('shl_add(5,7,4,5)',  shl_add(5, 7, 4, 5),  407);
    { c changed to 0 (wraps to byte cache zero-init): both patched }
    check('shl_add(10,1,0,1)', shl_add(10, 1, 0, 1),  11);
    halt(0);
end.
{$endif}
