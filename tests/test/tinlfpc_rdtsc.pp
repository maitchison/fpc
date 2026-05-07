{ %TARGET=i386 }
{ %RESULT=0 }
{
  Smoke test for the in_x86_rdtsc compiler intrinsic.

  fpc_x86_rdtsc is declared in rtl/i386/cpuprocs.inc with
  [internproc:fpc_in_x86_rdtsc]; the compiler expands it inline to a
  bare RDTSC opcode whose EDX:EAX result is plumbed through the
  register allocator as a 64-bit qword location.

  Verifies:
    1. The symbol exists and returns qword.
    2. Two consecutive reads are monotonic (t2 > t1) on real hardware.
       (TSC is a strictly increasing counter on every x86 since Pentium
       so this is safe across DOS, DPMI, Win32 hosts.)
    3. The 64-bit halves round-trip through codegen without truncation
       -- if either reglo/reghi were dropped we'd see t2 = 0 or
       constant-folded values.
}
program tinlfpc_rdtsc;

uses
  intrinsics;

var
  t1, t2: qword;
  i: longint;
  spin: longint;
begin
  t1 := fpc_x86_rdtsc;
  spin := 0;
  for i := 1 to 100000 do
    inc(spin);
  t2 := fpc_x86_rdtsc;

  if t2 <= t1 then halt(1);
  if (t2 - t1) < 100 then halt(2); { sanity: at least 100 cycles between }
  if spin <> 100000 then halt(3);  { make sure the loop wasn't DCE'd }
end.
