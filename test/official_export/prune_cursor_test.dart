// The carried `decoded_pruned_before` cursor (spec §4.3, P1 red cases).
//
// WHY: the fork's live cursor says "decoded rows below here were deleted". The
// official app reads the cursor to label cut days deleted and to make days that
// follow a cut abstain. Copying the fork's value unchanged is wrong in two
// directions: it stays low when mapped history starts mid-day (the oldest
// partial day is never labelled deleted), and it stays HIGH after exact archive
// expansion restored complete older days, so those days never become eligible.
// CLAIM(official-export-prune-edge). Expected epochs are literals computed with
// an independent zone database (python zoneinfo), not by the code under test.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/prune_cursor.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Midnight arithmetic from the zone database, independent of `DateTime.local`.
class _ZoneCalendar implements LocalCalendar {
  _ZoneCalendar(String zone) : _loc = tz.getLocation(zone);
  final tz.Location _loc;
  @override
  int midnightAtOrAfter(int sec) {
    final at = tz.TZDateTime.fromMillisecondsSinceEpoch(_loc, sec * 1000);
    final start = tz.TZDateTime(_loc, at.year, at.month, at.day);
    final next = tz.TZDateTime(_loc, at.year, at.month, at.day + 1);
    return (start.millisecondsSinceEpoch >= sec * 1000 ? start : next)
            .millisecondsSinceEpoch ~/
        1000;
  }
}

// zone -> label -> epoch seconds (days: 2026-10-20 = d1 … 2026-10-29 = d10).
const _t = <String, Map<String, int>>{
  'UTC': {
    'd1': 1792454400, 'd1+1s': 1792454401, 'd1 noon': 1792497600,
    'd1 23:59:59': 1792540799, 'd2': 1792540800, 'd3 noon': 1792670400,
    'd4': 1792713600, 'd5': 1792800000, 'd5 noon': 1792843200,
    'd6': 1792886400, 'd10': 1793232000,
  },
  'America/Denver': {
    'd1': 1792476000, 'd1+1s': 1792476001, 'd1 noon': 1792519200,
    'd1 23:59:59': 1792562399, 'd2': 1792562400, 'd3 noon': 1792692000,
    'd4': 1792735200, 'd5': 1792821600, 'd5 noon': 1792864800,
    'd6': 1792908000, 'd10': 1793253600,
  },
  'Asia/Kolkata': {
    'd1': 1792434600, 'd1+1s': 1792434601, 'd1 noon': 1792477800,
    'd1 23:59:59': 1792520999, 'd2': 1792521000, 'd3 noon': 1792650600,
    'd4': 1792693800, 'd5': 1792780200, 'd5 noon': 1792823400,
    'd6': 1792866600, 'd10': 1793212200,
  },
};

PrunedBeforeChoice _choose(String zone, {int? fork, int? oldest}) =>
    chooseDecodedPrunedBefore(
      forkCursorSec: fork,
      oldestExactSec: oldest,
      calendar: _ZoneCalendar(zone),
    );

void main() {
  setUpAll(tzdata.initializeTimeZones);

  for (final zone in _t.keys) {
    group(zone, () {
      final t = _t[zone]!;

      test('no fork cursor: no row, whatever the mapped input says', () {
        final c = _choose(zone, fork: null, oldest: t['d3 noon']);
        expect(c.sec, isNull);
        expect(c.reason, PrunedBeforeReason.noForkCursor);
      });

      test('no exact second survives mapping: fork value kept, none invented',
          () {
        final c = _choose(zone, fork: t['d5'], oldest: null);
        expect(c.sec, t['d5']);
        expect(c.reason, PrunedBeforeReason.noExactInput);
      });

      test('oldest exact second exactly at local midnight emits that midnight',
          () {
        final c = _choose(zone, fork: t['d10'], oldest: t['d1']);
        expect(c.sec, t['d1']);
        expect(c.reason, PrunedBeforeReason.oldestExactMidnight);
      });

      test('one second after midnight emits the NEXT midnight', () {
        expect(_choose(zone, fork: t['d10'], oldest: t['d1+1s']).sec, t['d2']);
      });

      test('mid-day oldest second emits the next midnight (oldest day cut)', () {
        final c = _choose(zone, fork: t['d10'], oldest: t['d1 noon']);
        expect(c.sec, t['d2']);
        expect(c.reason, PrunedBeforeReason.oldestExactMidnight);
      });

      test('one second before midnight emits that midnight', () {
        expect(
          _choose(zone, fork: t['d10'], oldest: t['d1 23:59:59']).sec,
          t['d2'],
        );
      });

      test('INVERSE: archive-restored days below a high fork cursor lower it',
          () {
        // Fork pruned everything below d10; exact archive expansion restored
        // complete days from d3 noon on. Emitting d10 unchanged would keep
        // those days cut. The edge is d4, far below the fork's value.
        final c = _choose(zone, fork: t['d10'], oldest: t['d3 noon']);
        expect(c.sec, t['d4']);
        expect(c.sec, lessThan(t['d10']!));
      });

      test('never above the fork: a later edge is capped at the fork cursor',
          () {
        // Fork cursor d5; mapped history starts d5 noon, so the edge would be
        // d6. The cut the fork itself proved stays at d5.
        final c = _choose(zone, fork: t['d5'], oldest: t['d5 noon']);
        expect(c.sec, t['d5']);
        expect(c.reason, PrunedBeforeReason.cappedAtForkCursor);
      });

      test('edge equal to the fork cursor is not a cap', () {
        final c = _choose(zone, fork: t['d5'], oldest: t['d5']);
        expect(c.sec, t['d5']);
        expect(c.reason, PrunedBeforeReason.oldestExactMidnight);
      });

      test('invalid fork cursors reject; non-positive exact seconds are absent',
          () {
        expect(() => _choose(zone, fork: 0, oldest: 1), throwsArgumentError);
        expect(() => _choose(zone, fork: -5, oldest: null), throwsArgumentError);
        for (final oldest in [null, 0, -1]) {
          final c = _choose(zone, fork: t['d5'], oldest: oldest);
          expect(c.sec, t['d5']);
          expect(c.reason, PrunedBeforeReason.noExactInput);
        }
      });
    });
  }

  group('DST days in America/Denver keep calendar midnights', () {
    test('fall-back day is 25 h: next midnight is 25 h after the last one', () {
      // 2026-11-01 00:30 MDT; the next local midnight is 2026-11-02 00:00 MST.
      final c = _choose('America/Denver', fork: 1794000000, oldest: 1793514600);
      expect(c.sec, 1793602800);
      expect(c.sec! - 1793512800, 25 * 3600);
    });

    test('spring-forward day is 23 h: next midnight is 23 h after the last one',
        () {
      // 2026-03-08 03:30 MDT; the next local midnight is 2026-03-09 00:00 MDT.
      final c = _choose('America/Denver', fork: 1794000000, oldest: 1772962200);
      expect(c.sec, 1773036000);
      expect(c.sec! - 1772953200, 23 * 3600);
    });
  });

  group('production calendar (process zone, whichever it is)', () {
    test('returns a local midnight at or after the input, within one day', () {
      const calendar = DayLabelCalendar();
      for (final sec in [1792454400, 1792454401, 1792497600, 1793514600]) {
        final r = calendar.midnightAtOrAfter(sec);
        final at = DateTime.fromMillisecondsSinceEpoch(r * 1000);
        expect(r, greaterThanOrEqualTo(sec));
        expect(r - sec, lessThanOrEqualTo(25 * 3600));
        expect([at.hour, at.minute, at.second], [0, 0, 0]);
      }
    });
  });
}
