// Journal items on the Explorer: what is read, how it becomes annotations, and
// how the chart shows them.
//
// Fixed dates only. The pure half builds annotations from rows already read;
// the widget half injects the loader, so no database is opened.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/ui2/screens/metric_annotations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';


const _day = '2026-10-03';
final int _start = localDayStartSec(_day)!;
final int _end = localDayEndSec(_day)!;
int _ts(int minute) => _start + minute * 60;

void main() {
  group('rangeAnnotations', () {
    test('every source becomes its own kind, on its own minute', () {
      final a = rangeAnnotations(
        from: '2026-10-03',
        to: '2026-10-04',
        sessions: [
          {'start_ts': _ts(18 * 60), 'end_ts': _ts(19 * 60), 'type': 'running'},
        ],
        momentLabels: [
          MomentLabel(date: _day, hhmm: '09:15', label: 'other', answeredAtMs: 1),
          MomentLabel(date: _day, hhmm: '11:00', label: 'water', answeredAtMs: 1),
        ],
        assumedWater: const [
          AssumedGlass(date: _day, atMin: 14 * 60, ml: 250),
        ],
        journalByDay: const {
          _day: {
            'water_ml': JournalMetricValue(500, atMinuteOfDay: 8 * 60),
            'caffeine': JournalMetricValue(1, atMinuteOfDay: 10 * 60),
            // No time: not placed anywhere.
            'alcohol': JournalMetricValue(2),
          },
        },
      );
      final by = {for (final x in a) x.at.toInt(): x};
      // The water total at 08:00 is an aggregate of the other water events,
      // not a sixth thing that happened.
      expect(a.length, 5);
      expect(by[_ts(8 * 60)], isNull);
      expect(by[_ts(9 * 60 + 15)]!.kind, AnnotationKind.moment);
      expect(by[_ts(10 * 60)]!.kind, AnnotationKind.journal);
      expect(by[_ts(11 * 60)]!.kind, AnnotationKind.water);
      expect(by[_ts(14 * 60)]!.kind, AnnotationKind.assumedWater);
      expect(by[_ts(18 * 60)]!.kind, AnnotationKind.workout);
      expect(by[_ts(18 * 60)]!.until, _ts(19 * 60).toDouble());
    });

    group('one real event, one annotation of its true kind', () {
      // `logAssumedWater` writes the assumed_water row AND adds to the day's
      // timed water_ml total; an answered water tap writes the label AND adds
      // to the same total. The total is never a second event.
      List<ChartAnnotation> water({
        List<AssumedGlass> glasses = const [],
        List<MomentLabel> taps = const [],
        Map<String, JournalMetricValue> journal = const {},
      }) =>
          rangeAnnotations(
            from: _day,
            to: _day,
            assumedWater: glasses,
            momentLabels: taps,
            journalByDay: {_day: journal},
          );

      test('an assumed glass is a droplet and nothing else', () {
        final a = water(
          glasses: const [AssumedGlass(date: _day, atMin: 14 * 60, ml: 250)],
          journal: const {
            'water_ml': JournalMetricValue(250, atMinuteOfDay: 14 * 60),
          },
        );
        expect([for (final x in a) x.kind], [AnnotationKind.assumedWater],
            reason: 'no normal-water icon, so no "+1" cluster either');
      });

      test('an answered water tap is one water mark', () {
        final a = water(
          taps: [
            MomentLabel(
                date: _day, hhmm: '11:00', label: 'water', answeredAtMs: 1),
          ],
          journal: const {
            'water_ml': JournalMetricValue(250, atMinuteOfDay: 11 * 60),
          },
        );
        expect([for (final x in a) x.kind], [AnnotationKind.water]);
      });

      test('several glasses and taps are exactly that many marks', () {
        final a = water(
          glasses: const [
            AssumedGlass(date: _day, atMin: 10 * 60, ml: 250),
            AssumedGlass(
                date: _day,
                atMin: 14 * 60,
                ml: 250,
                state: AssumedState.kept),
          ],
          taps: [
            MomentLabel(
                date: _day, hhmm: '11:00', label: 'water', answeredAtMs: 1),
          ],
          journal: const {
            'water_ml': JournalMetricValue(750, atMinuteOfDay: 14 * 60),
          },
        );
        expect(a.length, 3);
        expect(a.where((x) => x.kind == AnnotationKind.assumedWater).length, 2);
        expect(a.where((x) => x.kind == AnnotationKind.water).length, 1);
      });

      test('a removed latest glass leaves no water mark at its old slot', () {
        // removeAssumedWater subtracts the ml but keeps the row's at_min, so a
        // surviving total still points at the REMOVED 15:00 slot.
        final a = water(
          glasses: const [AssumedGlass(date: _day, atMin: 10 * 60, ml: 250)],
          journal: const {
            'water_ml': JournalMetricValue(250, atMinuteOfDay: 15 * 60),
          },
        );
        expect([for (final x in a) x.at], [_ts(10 * 60).toDouble()]);
        expect(a.single.kind, AnnotationKind.assumedWater);
      });

      test('a total with no event behind it is not a mark', () {
        expect(
            water(journal: const {
              'water_ml': JournalMetricValue(500, atMinuteOfDay: 8 * 60),
            }),
            isEmpty);
      });
    });

    test('an unfinished workout is a point at its start, never a made-up end',
        () {
      // end_ts is NULL while a session is live (or was never closed). The only
      // thing known is when it began; shading to "now" would claim it is still
      // going, so it stays a point mark.
      final a = rangeAnnotations(
        from: _day,
        to: _day,
        sessions: [
          {'start_ts': _ts(18 * 60), 'end_ts': null, 'type': 'running'},
        ],
      );
      expect(a.single.kind, AnnotationKind.workout);
      expect(a.single.at, _ts(18 * 60).toDouble());
      expect(a.single.until, isNull);
    });

    test('days outside from..to are left out', () {
      final a = rangeAnnotations(
        from: '2026-10-03',
        to: '2026-10-03',
        momentLabels: [
          MomentLabel(
              date: '2026-10-02', hhmm: '09:15', label: 'other', answeredAtMs: 1),
          MomentLabel(
              date: '2026-10-04', hhmm: '09:15', label: 'other', answeredAtMs: 1),
        ],
      );
      expect(a, isEmpty);
    });

    test('the same minute on two days gives two different ids', () {
      final a = rangeAnnotations(
        from: '2026-10-03',
        to: '2026-10-04',
        momentLabels: [
          MomentLabel(date: _day, hhmm: '09:15', label: 'other', answeredAtMs: 1),
          MomentLabel(
              date: '2026-10-04', hhmm: '09:15', label: 'other', answeredAtMs: 1),
        ],
      );
      expect(a.length, 2);
      expect({for (final x in a) x.id}.length, 2);
    });

    test('nothing read, nothing made up', () {
      expect(rangeAnnotations(from: _day, to: _day), isEmpty);
    });

    test('a skipped moment (no label) is not an annotation', () {
      final a = rangeAnnotations(
        from: _day,
        to: _day,
        momentLabels: [
          MomentLabel(date: _day, hhmm: '09:15', label: null, answeredAtMs: 1),
        ],
      );
      expect(a, isEmpty);
    });
  });

  group('napAnnotations', () {
    test('a detected nap is a range of kind nap on its day', () {
      final a = napAnnotations(_day, {
        'day_start': _start,
        'naps': [
          {'start': _ts(14 * 60), 'end': _ts(14 * 60 + 40), 'duration_min': 40},
        ],
      });
      expect(a.length, 1);
      expect(a.single.kind, AnnotationKind.nap);
      expect(a.single.id, '$_day/nap:${_ts(14 * 60)}');
      expect(a.single.at, _ts(14 * 60).toDouble());
      expect(a.single.until, _ts(14 * 60 + 40).toDouble());
    });

    test('no naps, or a timeline without them, make nothing', () {
      expect(napAnnotations(_day, {'day_start': _start, 'naps': const []}),
          isEmpty);
      expect(napAnnotations(_day, const {}), isEmpty);
    });

    test('only naps: sleep, sessions and the rest of the timeline are not read',
        () {
      final a = napAnnotations(_day, {
        'day_start': _start,
        'sleep': [
          {'onset_ts': _ts(-60), 'wake_ts': _ts(420)},
        ],
        'sessions': [
          {'start_ts': _ts(1020), 'end_ts': _ts(1080), 'type': 'running'},
        ],
      });
      expect(a, isEmpty);
    });
  });


}
