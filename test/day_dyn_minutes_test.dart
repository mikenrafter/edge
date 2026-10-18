// The per-minute motion buckets the engine folds (DayDynMinutes) give, bit for
// bit, the minutes `enmoSeries` gives for the fields the app reads, also when the
// day is folded in pieces through the stored blob (a restart between passes).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';

void main() {
  test('folded in pieces through the blob equals enmoSeries', () {
    final r = math.Random(3);
    final ts = <int>[], hr = <int>[];
    final ax = <double>[], ay = <double>[], az = <double>[];
    var t = 1760000000;
    for (var i = 0; i < 40000; i++) {
      // Gaps longer than the gravity window, short skips, no-HR seconds and
      // all-zero (absent) gravity vectors.
      t += (i % 5003 == 0) ? 200 : (r.nextInt(40) == 0 ? 3 : 1);
      ts.add(t);
      hr.add(r.nextInt(30) == 0 ? 0 : 60 + r.nextInt(40));
      if (r.nextInt(25) == 0) {
        ax.add(0);
        ay.add(0);
        az.add(0);
      } else {
        ax.add(r.nextDouble() * .5);
        ay.add(r.nextDouble() * .3 - .1);
        az.add(1 + r.nextDouble() * .1);
      }
    }
    final want = ana.enmoSeries([
      for (var i = 0; i < ts.length; i++)
        ana.AccelSample(ts[i] * 1000.0, ax[i], ay[i], az[i],
            valid: hr[i] > 0 && (ax[i] != 0 || ay[i] != 0 || az[i] != 0)),
    ], expectedMinutes: 1440).minutes;

    Uint8List? blob;
    var at = 0;
    for (final n in [100, 7000, 9999, 20000, 40000]) {
      blob = foldDayCheckpoint(
        base: blob,
        alreadyFolded: at,
        ts: ts.sublist(at, n),
        hr: hr.sublist(at, n),
        ax: ax.sublist(at, n),
        ay: ay.sublist(at, n),
        az: az.sublist(at, n),
        stepCounter: List.filled(n - at, -1),
        age: 35,
        stepModulus: null,
      );
      expect(blob, isNotNull);
      at = n;
    }
    final got = decodeDayResumeState(blob!)!.dyn.minutes();
    expect(got.length, want.length);
    for (var i = 0; i < want.length; i++) {
      expect(got[i].tsMinStartMs, want[i].tsMinStartMs);
      expect(got[i].nSamples, want[i].nSamples);
      expect(got[i].dynAmp, want[i].dynAmp, reason: 'minute $i');
    }
  });
}
