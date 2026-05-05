{ %OPT=-Sew }
{ %RESULT=0 }
{
  Regression: `var x: T align N;` should NOT emit W02114
  ("align directive larger than system maximum alignment for variables")
  when N is within the target's varalignmax. Pre-fix logic in
  ngenutil.insertbssdata compared the request against the type's
  natural alignment instead of the system max, so e.g.
    var buf: array[0..3] of word align 8;
  warned even though the BSS slot was correctly aligned to 8 (via the
  per-section COFF alignment flags landed for go32v2).

  -Sew turns warnings into errors, so the test fails compile if the
  warning re-appears. Compile-only -- correctness of the resulting
  alignment is covered by share\aligntst.pas under DOSBox-X.
}
program tinlfpc_align_no_warn;

{$mode objfpc}{$H+}

{ All alignments here are <= 8 so the test is portable to go32v2
  (varalignmax=8) as well as to wider targets. The bug was that the
  warning fired whenever explicit > type-natural alignment, even when
  the request was within varalignmax. }
var
  buf_w8 : array[0..3] of word align 8;
  buf_b8 : array[0..7] of byte align 8;
  q8     : qword align 8;

begin
  { Touch each so they aren't optimised away on link. }
  buf_w8[0] := 0;
  buf_b8[0] := 0;
  q8        := 0;
end.
