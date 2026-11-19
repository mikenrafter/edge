import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/sync_strip_policy.dart';

void main() {
  // why: m334 gives two thirds to real data and caps that part at 16 h.
  // catches: using the last two hours for every backlog, or shrinking real data.
  test('window follows backlog, caught up and compressed cases', () {
    const away=SyncStripWindow(now:100000,last:96400);
    expect(away.missing,3600); expect(away.start,89200);
    expect(away.realFraction,2/3); expect(away.compressed,false);
    const caught=SyncStripWindow(now:100000,last:100000,connected:true,reportedNewest:100000);
    expect(caught.realSeconds,7200); expect(caught.realFraction,1);
    const long=SyncStripWindow(now:200000,last:27200);
    expect(long.realSeconds,57600); expect(long.start,-30400);
    expect(long.compressed,true); expect(long.realFraction,2/3);
  });
  // why: an offline estimate cannot promise that any data exists on the band.
  // catches: treating connection alone, corrupt RTC or absent input as evidence.
  test('band label requires a usable report and durable frontier', () {
    const known=SyncStripWindow(now:100000,last:96400,connected:true,reportedNewest:99900);
    expect(known.reported,true); expect(known.label,'On your band');
    for(final w in [
      const SyncStripWindow(now:100000,last:96400,reportedNewest:99900),
      const SyncStripWindow(now:100000,last:96400,connected:true),
      const SyncStripWindow(now:100000,last:96400,connected:true,reportedNewest:96400),
      const SyncStripWindow(now:100000,last:96400,connected:true,reportedNewest:999999999),
    ]) { expect(w.reported,false); expect(w.label,'Maybe on your band'); }
    const absent=SyncStripWindow(now:100000,last:null);
    expect(absent.missing,0);expect(absent.statusLabel,'No synced records yet');
  });
}
