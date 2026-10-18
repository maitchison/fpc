{ A huge block reuses the smallest cached chunk that fits it.

  Without SysOSFree (go32v2) a freed huge chunk is cached whole and handed out whole to a later request it fits, and
  MemSize reports the whole chunk. First fit gave the 1.5 Mb request below the 6 Mb chunk, freed first; best fit gives it
  one of the 1.5 Mb chunks. With SysOSFree nothing is cached and every request gets a chunk of its own size. }

program theapbestfit;

const
  Mb = 1024 * 1024;
  Big = 6 * Mb;
  Small = 3 * Mb div 2;

var
  big1, small1, small2, again1, again2: pointer;

begin
  getmem(big1, Big);
  getmem(small1, Small);
  getmem(small2, Small);
  freemem(big1);
  freemem(small1);
  freemem(small2);

  getmem(again1, Small);
  if MemSize(again1) >= Small + Mb then
    begin
      writeln('1.5 Mb request got a ', MemSize(again1) div 1024, ' Kb chunk');
      halt(1);
    end;
  getmem(again2, Small);
  if MemSize(again2) >= Small + Mb then
    begin
      writeln('second 1.5 Mb request got a ', MemSize(again2) div 1024, ' Kb chunk');
      halt(2);
    end;
  { The 6 Mb chunk is still there for a request of its size. }
  getmem(big1, Big);
  if MemSize(big1) < Big then
    halt(3);
  freemem(big1);
  freemem(again2);
  freemem(again1);
  writeln('ok');
end.
