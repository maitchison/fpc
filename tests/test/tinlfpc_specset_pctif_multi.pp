{ %OPT=-Si }
{ %RESULT=0 }

{ Verifies multiple %if blocks inside a single specset asm body --
  pattern matches the YOG `yog_to_16_mmx' use case where dither adds
  appear at several points in the hot loop, all gated on the same
  specset boolean. }
program tinlfpc_specset_pctif_multi;

{$mode objfpc}{$asmmode intel}

var
  g_result: longint;

procedure foo(x: boolean specialize [true, false]);
begin
  g_result := 0;
  asm
    mov eax, g_result
    %if x
      add eax, 10
    %endif
    add eax, 1
    %if x
      add eax, 100
    %endif
    add eax, 2
    %if x
      add eax, 1000
    %endif
    mov g_result, eax
  end;
  writeln(g_result);
end;

begin
  foo(true);   { 0 + 10 + 1 + 100 + 2 + 1000 = 1113 }
  foo(false);  { 0      + 1       + 2        =    3 }
end.
