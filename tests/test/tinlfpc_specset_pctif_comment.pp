{ %OPT=-Si }
{ %RESULT=0 }

{
  Regression: Pascal-style block comments inside a specialize-set asm
  body must not perturb the asm-source side-channel capture.

  The pspecset SS-B path captures the user asm body as raw chars (via
  begin_specset_asm_capture / end_specset_asm_capture) so each per-value
  wrapper can replay it through substitutemacro. Comment skipping uses
  scanner.readchar, which bypasses asmgetchar -- so without explicit
  capture in the skipcomment family, the comment text is missing from
  the replay buffer. The replay then sees an unbalanced opening brace,
  runs skipcomment past EOF of the synthetic input, and lands inside
  the surrounding source -- making the next unrelated proc fail to
  parse with cascading "Unrecognized opcode ASM" / "Unknown identifier"
  errors.

  This is exactly what hit dev/video/yog_mmx.inc once yog_to_16_mmx
  picked up the new specset+pctif pattern: yog_to_32_mmx (the next proc
  in the file) suddenly stopped parsing.

  Each comment form that the asm reader hands off to a scanner helper
  is exercised here: curly-brace, paren-star, and double-slash.
}

program tinlfpc_specset_pctif_comment;

{$mode objfpc}{$asmmode intel}

var
  g_a, g_b: longint;

procedure first(x: boolean specialize [true, false]);
begin
  asm
    mov eax, g_a
    {curly-brace comment}
    %if x
    add eax, 100
    %endif
    add eax, 1
    (* paren-star comment *)
    %if x
    add eax, 1000
    %endif
    add eax, 2
    // line comment
    %if x
    add eax, 10000
    %endif
    mov g_a, eax
  end;
end;

{
  A second proc with its own asm body. Pre-fix, parsing this proc
  exploded with "Unrecognized opcode ASM" because the wrapper replay
  for first had eaten through the surrounding source while looking
  for a closing brace. Post-fix the asm-source capture preserves
  comment chars and replay terminates cleanly inside the synthetic.
}
procedure second();
begin
  asm
    mov eax, g_b
    add eax, 5
    mov g_b, eax
  end;
end;

begin
  g_a := 0;
  g_b := 0;
  first(true);
  second();
  { With x=true:  0 + 100 + 1 + 1000 + 2 + 10000 = 11103, g_b: 0 + 5 = 5 }
  if g_a <> 11103 then halt(1);
  if g_b <> 5     then halt(2);

  g_a := 0;
  first(false);
  { With x=false: 0 + 1 + 2 = 3 }
  if g_a <> 3     then halt(3);
end.
