{ %OPT=-Sg }
{ %RESULT=0 }
{
  feature/codegen-proc smoke test #2 -- pointer codegen + memory
  operand displacement.

  Verifies the asm reader recognises a codegen-pointer ident used
  as a memory-reference base address (`p[ecx*4]'), encodes the
  instruction with disp32=$80000000 placeholder, and emits a
  `cg_<paramname>:' label AFTER the instruction. The preprocessor's
  auto-injected prologue patches the disp32 bytes via
  `(PPointer(@cg_p) - 1)^' on each changed-pointer call.

  fetch_at(p, idx) returns `(longint^)(p + idx*4)'.
}
program tinlfpc_codegen_ptr;

{$asmmode intel}

{ codegen-proc requires writable code pages -- the prologue patches
  the encoded instruction's disp32 bytes at runtime. Win32 GPFs on
  the patch write (W^X). go32v2 / DOS code pages are RW by default.
  Other targets: pass-through halt(0). }
{$ifndef GO32V2}
begin
    halt(0);
end.
{$else}

type
    TArr = array[0..9] of longint;

var
    arr1: TArr = (10, 20, 30, 40, 50, 60, 70, 80, 90, 100);
    arr2: TArr = ( 1,  2,  3,  4,  5,  6,  7,  8,  9,  10);

function fetch_at(p: pointer codegen; idx: longint): longint;
begin
    asm
        mov   ecx, idx
        mov   eax, p[ecx*4]   // codegen pointer -> disp32 patch site
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
    { First call: cache nil != @arr1, patch fires. }
    check('fetch_at(@arr1, 0)', fetch_at(@arr1, 0),  10);
    { p unchanged, cache hit: no patch. }
    check('fetch_at(@arr1, 5)', fetch_at(@arr1, 5),  60);
    check('fetch_at(@arr1, 9)', fetch_at(@arr1, 9), 100);
    { p switches to @arr2: cache miss, patch fires. }
    check('fetch_at(@arr2, 3)', fetch_at(@arr2, 3),   4);
    check('fetch_at(@arr2, 9)', fetch_at(@arr2, 9),  10);
    { p switches back to @arr1: cache miss again, patch fires. }
    check('fetch_at(@arr1, 0)', fetch_at(@arr1, 0),  10);
    halt(0);
end.
{$endif}
