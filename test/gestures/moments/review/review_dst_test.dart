// Round 2, P2-7: the clocks go back. A mark keeps only a wall-clock minute
// (`moment 01:50`), and on the fall-back night that minute happens twice, so a
// range built from two such marks could be reversed or given another length.
//
// Fix, pinned here without a DST zone (the suite runs under TZ=UTC, so the
// zone's own answer is injected):
//   * a mark made in the repeated hour also records its ABSOLUTE time, as a
//     second tag `moment-at HH:mm <epoch seconds>`;
//   * ranges are ordered and measured from absolute seconds;
//   * a mark whose minute is ambiguous and has no absolute time (an old mark)
//     is never paired: the wearer is told, nothing is guessed.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_apply.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_stamp.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';

import '../../../support/moment_review_fakes.dart';

// Denver, Sunday 2026-11-01, clocks go back at 02:00 MDT to 01:00 MST. One
// stored wall minute can be either side. Epochs are real UTC instants.
// 01:50 MDT = 07:50 UTC ; 01:10 MST = 08:10 UTC (20 minutes later).
final int _t0150mdt = DateTime.utc(2026, 11, 1, 7, 50).millisecondsSinceEpoch ~/ 1000;
final int _t0110mst = DateTime.utc(2026, 11, 1, 8, 10).millisecondsSinceEpoch ~/ 1000;

// Wall-clock labels as they were stored, plus their absolute time.
final late0150 = PendingMoment(date: '2026-11-01', hhmm: '01:50', epochSec: _t0150mdt);
final late0110 = PendingMoment(date: '2026-11-01', hhmm: '01:10', epochSec: _t0110mst);
const oldMark = PendingMoment(date: '2026-11-01', hhmm: '01:30', ambiguous: true);

bool _repeatedHour(DateTime t) => t.hour == 1 && t.minute <= 59;

void main() {
  group('absolute time of a mark', () {
    test('sec is the recorded epoch, else the wall clock', () {
      expect(late0150.sec, _t0150mdt);
      expect(mA.sec, sec(2026, 10, 6, 9, 15));
    });

    test('local is built from the epoch when there is one', () {
      expect(late0150.local.millisecondsSinceEpoch, _t0150mdt * 1000);
    });
  });

  group('ordering and length come from absolute time', () {
    test('01:50 (first pass) then 01:10 (second pass) is START then END even '
        'though the wall clock reads backwards', () {
      final q = MomentReviewQueue.empty
          .withRange(late0110, late0150, MomentChoice.nap);
      final r = q.ranges.single;
      expect(r.startKey, late0150.key);
      expect(r.endKey, late0110.key);
      expect(r.startSec, _t0150mdt);
      expect(r.endSec, _t0110mst);
      expect(r.endSec! - r.startSec!, 20 * 60);
    });

    test('the same range survives JSON in that order', () {
      final q = MomentReviewQueue.empty
          .withRange(late0150, late0110, MomentChoice.workout);
      final back = MomentReviewQueue.fromJson(q.toJson());
      expect(back.ranges.single.startKey, late0150.key);
      expect(back.ranges.single.endSec! - back.ranges.single.startSec!, 1200);
    });

    test('Save writes the 20 real minutes, not a reversed or 40-minute window',
        () async {
      final ranges = FakeRangeWriter();
      final rep = await MomentReviewApplier(
              writer: FakeAnswerWriter(),
              assumedWriter: FakeGlassWriter(),
              ranges: ranges,
              exporter: TaskerMomentExport(connectionOn: () => false))
          .apply(
              MomentReviewQueue.empty
                  .withRange(late0150, late0110, MomentChoice.workout),
              moments: [late0150, late0110],
              glasses: const [],
              now: DateTime.utc(2026, 11, 2).toLocal());
      expect(rep.failed, isEmpty);
      expect(ranges.loggedWorkouts.single.startSec, _t0150mdt);
      expect(ranges.loggedWorkouts.single.endSec, _t0110mst);
    });
  });

  group('an ambiguous mark with no absolute time is never paired', () {
    test('withRange refuses it', () {
      expect(
          () => MomentReviewQueue.empty
              .withRange(oldMark, late0110, MomentChoice.nap),
          throwsArgumentError);
      expect(
          () => MomentReviewQueue.empty
              .withRange(late0110, oldMark, MomentChoice.nap),
          throwsArgumentError);
    });

    test('a queued range that holds one fails at Save and writes nothing',
        () async {
      final ranges = FakeRangeWriter();
      final q = MomentReviewQueue.empty.withRangeProgress(const ReviewRange(
          choice: MomentChoice.nap,
          startKey: '2026-11-01 01:30',
          endKey: '2026-11-01 01:50'));
      final rep = await MomentReviewApplier(
              writer: FakeAnswerWriter(),
              assumedWriter: FakeGlassWriter(),
              ranges: ranges,
              exporter: TaskerMomentExport(connectionOn: () => false))
          .apply(q,
              moments: [oldMark, late0150],
              glasses: const [],
              now: DateTime.utc(2026, 11, 2).toLocal());
      expect(rep.failed, hasLength(1));
      expect(ranges.loggedNaps, isEmpty);
    });

    test('a single (unpaired) answer for it still works', () async {
      final w = FakeAnswerWriter();
      final rep = await MomentReviewApplier(
              writer: w,
              assumedWriter: FakeGlassWriter(),
              exporter: TaskerMomentExport(connectionOn: () => false))
          .apply(
              MomentReviewQueue.empty.withDecision(
                  ReviewKey.moment(oldMark), const ReviewDecision.skip()),
              moments: [oldMark],
              glasses: const [],
              now: reviewNow);
      expect(rep.failed, isEmpty);
      expect(w.skips, [oldMark.key]);
    });
  });

  group('how the marks are read', () {
    test('parseAbsolute reads `moment-at HH:mm <epoch>` tags, per day', () {
      final got = MomentFollowUps.parseAbsolute([
        {
          'date': '2026-11-01',
          'tags_json':
              '["moment 01:50","moment-at 01:50 $_t0150mdt","run","moment-at 99:99 5","moment-at 01:10 x"]'
        },
        {'date': '2026-11-02', 'tags_json': 'not json'},
      ]);
      expect(got, {'2026-11-01 01:50': _t0150mdt});
    });

    test('parseMarked still sees only the plain `moment HH:mm` tags', () {
      final got = MomentFollowUps.parseMarked([
        {
          'date': '2026-11-01',
          'tags_json': '["moment 01:50","moment-at 01:50 $_t0150mdt"]'
        }
      ]);
      expect(got, [(date: '2026-11-01', hhmm: '01:50')]);
    });

    test('pending() attaches the absolute time and flags the ambiguous rest',
        () {
      final f = MomentFollowUps(
        enabledSince: DateTime(2026, 10, 1),
        marked: const [
          (date: '2026-11-01', hhmm: '01:50'),
          (date: '2026-11-01', hhmm: '01:30'),
          (date: '2026-11-01', hhmm: '09:00'),
        ],
        absolute: {'2026-11-01 01:50': _t0150mdt},
        isAmbiguous: _repeatedHour,
      );
      final p = f.pending(DateTime(2026, 11, 2, 12));
      final by = {for (final m in p) m.hhmm: m};
      expect(by['01:50']!.epochSec, _t0150mdt);
      expect(by['01:50']!.ambiguous, isFalse, reason: 'its time is known');
      expect(by['01:30']!.epochSec, isNull);
      expect(by['01:30']!.ambiguous, isTrue);
      expect(by['09:00']!.ambiguous, isFalse);
    });

    test('under TZ=UTC no minute is ambiguous', () {
      expect(wallMinuteIsAmbiguous(DateTime(2026, 11, 1, 1, 30)), isFalse);
    });
  });

  group('how a mark is written', () {
    StrapEvent tap(DateTime at) {
      final ms = at.millisecondsSinceEpoch;
      return StrapEvent(
          eventId: 14,
          tsEpoch: ms ~/ 1000,
          tsSubsec: 0,
          receivedAt: at.add(const Duration(seconds: 2)),
          hex: '',
          deviceId: 'd');
    }

    test('an unambiguous tap writes just `moment HH:mm`, as before', () {
      final at = DateTime(2026, 10, 6, 9, 15, 30);
      final s = momentStampFor(tap(at), isAmbiguous: (_) => false);
      expect(s.ambiguous, isFalse);
      expect(s.epochSec, at.millisecondsSinceEpoch ~/ 1000);
      expect(withMomentTag(const [], s), ['moment 09:15']);
    });

    test('a tap in the repeated hour also records its absolute time', () {
      final at = DateTime(2026, 10, 6, 1, 50, 10);
      final s = momentStampFor(tap(at), isAmbiguous: _repeatedHour);
      expect(s.ambiguous, isTrue);
      expect(withMomentTag(const [], s),
          ['moment 01:50', 'moment-at 01:50 ${at.millisecondsSinceEpoch ~/ 1000}']);
    });

    test('and only once', () {
      final at = DateTime(2026, 10, 6, 1, 50, 10);
      final s = momentStampFor(tap(at), isAmbiguous: _repeatedHour);
      final once = withMomentTag(const [], s);
      expect(withMomentTag(once, s), once);
    });
  });
}
