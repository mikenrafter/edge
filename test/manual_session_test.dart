// Manual / retimed workout logging — the pure policy layer.
//
// Context: the auto-detector reports the HARD-EFFORT CORE (>=0.45*HRR held
// >=12 min, dips >90 s break the span), so an hour of mixed-intensity training
// commonly lands as ~25 detected minutes. `manual_session.dart` is what lets
// the athlete state the real window; these tests pin the parts that decide
// what gets written, without a DB or a clock in the way.
//
// The load-bearing guarantee is the honesty contract: a window with no 1 Hz HR
// behind it (pruned past the `rawRetentionDays` `decoded_onehz` retention, or
// band off) must produce NULL strain/calories — never a figure inferred from
// duration.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/compute/profile.dart';

/// The ONE ceiling for [_profile] since TS-03a: estimatedMaxHr(30, 'gen4'|'gen5')
/// = Tanaka 208 - 0.7*30 = 187. It bands the zones AND anchors TRIMP/Keytel;
/// the tests used to pass 190 for zones and let the scorer derive 187 for the
/// anchors, which is exactly the split TS-03a removed.
const _hrMax = 187.0;

/// A full profile — every anchor the scored metrics need.
const _profile = Profile(
  ageYears: 30,
  weightKg: 75,
  heightCm: 180,
  sex: 'm',
  restingHrManual: 55,
);

/// 1 Hz samples at a flat [bpm] for [minutes], starting at [start].
({List<int> ts, List<int> bpm}) _flat(int start, int minutes, int bpm) {
  final ts = <int>[];
  final hr = <int>[];
  for (var i = 0; i < minutes * 60; i++) {
    ts.add(start + i);
    hr.add(bpm);
  }
  return (ts: ts, bpm: hr);
}

void main() {
  group('validateManualWindow', () {
    const now = 1_700_000_000;

    test('accepts an ordinary past window', () {
      expect(
        validateManualWindow(
          startSec: now - 3600,
          endSec: now - 1800,
          nowSec: now,
        ),
        isNull,
      );
    });

    test('rejects end <= start', () {
      expect(
        validateManualWindow(startSec: now - 60, endSec: now - 60, nowSec: now),
        ManualWindowError.endNotAfterStart,
      );
      expect(
        validateManualWindow(startSec: now - 60, endSec: now - 120, nowSec: now),
        ManualWindowError.endNotAfterStart,
      );
    });

    test('rejects a sub-minute window but accepts exactly a minute', () {
      expect(
        validateManualWindow(startSec: now - 59, endSec: now, nowSec: now),
        ManualWindowError.tooShort,
      );
      expect(
        validateManualWindow(startSec: now - 60, endSec: now, nowSec: now),
        isNull,
      );
    });

    test('rejects beyond the 24 h typo guard, accepts exactly 24 h', () {
      expect(
        validateManualWindow(
          startSec: now - kMaxManualWorkoutSec - 1,
          endSec: now,
          nowSec: now,
        ),
        ManualWindowError.tooLong,
      );
      expect(
        validateManualWindow(
          startSec: now - kMaxManualWorkoutSec,
          endSec: now,
          nowSec: now,
        ),
        isNull,
      );
    });

    test('rejects a window ending in the future', () {
      expect(
        validateManualWindow(
          startSec: now - 1800,
          endSec: now + 1,
          nowSec: now,
        ),
        ManualWindowError.inFuture,
      );
    });

    test('rejects overlap but allows back-to-back sessions', () {
      final existing = [SessionSpan('a', now - 7200, now - 3600)];
      // Overlapping by a single second.
      expect(
        validateManualWindow(
          startSec: now - 3601,
          endSec: now - 1800,
          nowSec: now,
          existing: existing,
        ),
        ManualWindowError.overlapsExisting,
      );
      // Touching end-to-start is legitimate (a brick session, back-to-back).
      expect(
        validateManualWindow(
          startSec: now - 3600,
          endSec: now - 1800,
          nowSec: now,
          existing: existing,
        ),
        isNull,
      );
    });

    test('fully-contained and fully-containing windows both count as overlap', () {
      final existing = [SessionSpan('a', now - 7200, now - 3600)];
      // New window swallows the existing one — the widen-a-fragment case, which
      // must be an EDIT, not a second row.
      expect(
        validateManualWindow(
          startSec: now - 7800,
          endSec: now - 3000,
          nowSec: now,
          existing: existing,
        ),
        ManualWindowError.overlapsExisting,
      );
      // New window sits inside the existing one.
      expect(
        validateManualWindow(
          startSec: now - 6000,
          endSec: now - 5000,
          nowSec: now,
          existing: existing,
        ),
        ManualWindowError.overlapsExisting,
      );
    });

    test('editingId excludes the row being retimed from its own overlap check', () {
      final existing = [SessionSpan('a', now - 7200, now - 3600)];
      // Widening 'a' overlaps 'a' — without the exclusion this is unfixable.
      expect(
        validateManualWindow(
          startSec: now - 7800,
          endSec: now - 3000,
          nowSec: now,
          existing: existing,
          editingId: 'a',
        ),
        isNull,
      );
    });

    test('a stranded live row (no usable end) is skipped, not guessed at', () {
      final existing = [SessionSpan('live', now - 3600, 0)];
      expect(
        validateManualWindow(
          startSec: now - 3600,
          endSec: now - 1800,
          nowSec: now,
          existing: existing,
        ),
        isNull,
      );
    });

    test('every error carries user-facing copy', () {
      for (final e in ManualWindowError.values) {
        expect(e.message, isNotEmpty);
      }
    });
  });

  group('hrPerMinute', () {
    test('collapses 1 Hz samples to one entry per minute', () {
      final s = _flat(0, 10, 140);
      final perMin = hrPerMinute(s.ts, s.bpm);
      expect(perMin.length, 10);
      expect(perMin.every((v) => v == 140.0), isTrue);
    });

    test('averages within a minute', () {
      // 30 s at 100, 30 s at 200 inside one minute bucket.
      final ts = [for (var i = 0; i < 60; i++) i];
      final bpm = [for (var i = 0; i < 60; i++) i < 30 ? 100 : 200];
      expect(hrPerMinute(ts, bpm), [150.0]);
    });

    test('a gap produces no entry rather than a zero minute', () {
      // Minute 0 present, minute 1 absent, minute 2 present.
      final ts = <int>[0, 1, 2, 120, 121, 122];
      final bpm = <int>[120, 120, 120, 130, 130, 130];
      expect(hrPerMinute(ts, bpm), [120.0, 130.0]);
    });

    test('empty and mismatched inputs yield nothing', () {
      expect(hrPerMinute(const [], const []), isEmpty);
      expect(hrPerMinute(const [1, 2], const [100]), isEmpty);
    });
  });

  group('zoneMinutesFor', () {
    test('is exactly what computeManualSessionStats reports', () {
      // The session scorer must not fork its own copy of the method.
      final w = _flat(0, 45, 150);
      final viaStats = computeManualSessionStats(
        hrTs: w.ts,
        hrBpm: w.bpm,
        profile: _profile,
        hrMax: _hrMax,
        restingHr: 55,
        quietHrr: 0.20,
      ).strain;
      final direct = strainFromPerMinuteHr(hrPerMinute(w.ts, w.bpm),
          profile: _profile, restingHr: 55, hrMax: _hrMax, quietHrr: 0.20);
      expect(viaStats, direct);
    });
  });

  group('buildManualSessionRow', () {
    final scored = computeManualSessionStats(
      hrTs: _flat(1000, 60, 150).ts,
      hrBpm: _flat(1000, 60, 150).bpm,
      profile: _profile,
      hrMax: _hrMax,
      restingHr: 55,
      quietHrr: 0.20,
    );

    test('a new entry is done/manual with a start-keyed id', () {
      final row = buildManualSessionRow(
        startSec: 1000,
        endSec: 1000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 5_000_000,
      );
      expect(row['id'], 'manual:1000');
      expect(row['status'], 'done');
      expect(row['source'], 'manual');
      expect(row['type'], 'run');
      expect(row['duration_min'], 60);
      expect(row['created_at'], 5_000_000);
      expect(row['strain'], isNotNull);
      expect(row['calories'], isNotNull);
    });

    test('re-logging the same window is idempotent on id', () {
      expect(manualSessionId(1000), manualSessionId(1000));
      expect(manualSessionId(1000), isNot(manualSessionId(1001)));
    });

    test('an edit preserves id, source and created_at', () {
      final row = buildManualSessionRow(
        startSec: 2000,
        endSec: 2000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 9_999_999,
        existing: const {
          'id': 'auto:1234',
          'source': 'auto',
          'created_at': 111,
        },
      );
      // Retiming must not re-attribute how the session was captured — the
      // detail screen's AUTO tag reads `source`.
      expect(row['id'], 'auto:1234');
      expect(row['source'], 'auto');
      expect(row['created_at'], 111);
      // ...but the window itself is the new one.
      expect(row['start_ts'], 2000);
      expect(row['duration_min'], 60);
    });

    test('absent stats are written as explicit nulls, not omitted', () {
      // putSession is INSERT-OR-REPLACE: an omitted key on an edit would let a
      // stale value computed for the OLD window survive into the new one.
      final row = buildManualSessionRow(
        startSec: 3000,
        endSec: 3000 + 3600,
        type: 'other',
        stats: const ManualSessionStats(),
        createdAtMs: 1,
      );
      for (final k in ['calories', 'strain', 'max_hr', 'steps', 'hrr_bpm']) {
        expect(row.containsKey(k), isTrue, reason: '$k must be present');
        expect(row[k], isNull, reason: '$k must be explicitly null');
      }
      // An unscored session still records the window the athlete asserted.
      expect(row['duration_min'], 60);
      expect(row['status'], 'done');
    });

    test('steps and hrr are cleared on a retime', () {
      final row = buildManualSessionRow(
        startSec: 4000,
        endSec: 4000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 1,
        existing: const {
          'id': 'w1',
          'source': 'manual',
          'created_at': 2,
          'steps': 4321,
          'hrr_bpm': 22.5,
        },
      );
      // Both described the OLD window; hrr_bpm is refilled by derivation.
      expect(row['steps'], isNull);
      expect(row['hrr_bpm'], isNull);
    });

    test('zone_min_json is a JSON list, empty when there are no zones', () {
      final unscored = buildManualSessionRow(
        startSec: 5000,
        endSec: 5000 + 3600,
        type: 'other',
        stats: const ManualSessionStats(),
        createdAtMs: 1,
      );
      expect(jsonDecode(unscored['zone_min_json'] as String), isEmpty);

      final withZones = buildManualSessionRow(
        startSec: 5000,
        endSec: 5000 + 3600,
        type: 'run',
        stats: scored,
        createdAtMs: 1,
      );
      final decoded = jsonDecode(withZones['zone_min_json'] as String) as List;
      expect(decoded.length, 5);
      expect(decoded.cast<num>().any((v) => v > 0), isTrue);
    });
  });

  group('supersededSuggestionIds', () {
    Map<String, dynamic> sug(String id, int start, int end) =>
        {'id': id, 'start_ts': start, 'end_ts': end};

    test('retires the fragment a wider manual entry covers', () {
      // The reported case: the detector found 25 min inside a 60 min session.
      final ids = supersededSuggestionIds(
        [sug('s1', 1500, 3000)],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, ['s1']);
    });

    test('leaves an unrelated suggestion alone', () {
      final ids = supersededSuggestionIds(
        [sug('s1', 10000, 12000)],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, isEmpty);
    });

    test('a merely adjacent suggestion is not superseded', () {
      final ids = supersededSuggestionIds(
        [sug('s1', 3600, 5000)],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, isEmpty);
    });

    test('malformed rows are skipped, not crashed on', () {
      final ids = supersededSuggestionIds(
        [
          {'id': null, 'start_ts': 0, 'end_ts': 100},
          {'id': 's2', 'start_ts': null, 'end_ts': 100},
          {'id': 's3', 'start_ts': 200, 'end_ts': 100}, // inverted
          sug('s4', 100, 200),
        ],
        startSec: 0,
        endSec: 3600,
      );
      expect(ids, ['s4']);
    });
  });
}
