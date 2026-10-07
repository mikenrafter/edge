// MomentFollowUps — which marked moments still need an answer.
//
// A marked moment is a journal tag `moment HH:mm` on its LOCAL day. It is
// pending when (1) the follow-up setting was on when it was marked, (2) it has
// no answer yet (a skip is an answer), and (3) it is at most 7 local calendar
// days old. Pure: no database, no clock.
//
// Run under TZ=UTC by the harness, so the DST cases are pinned by wall-clock
// construction and by a source guard (no 86400 / Duration(days:) / toUtc).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';

import '../../support/dart_source_lexical.dart';

final _now = DateTime(2026, 10, 7, 12, 0);

MarkedMoment _m(String date, String hhmm) => (date: date, hhmm: hhmm);

MomentFollowUps _f({
  DateTime? since,
  List<MarkedMoment> marked = const [],
  Set<String> labelled = const {},
}) =>
    MomentFollowUps(enabledSince: since, marked: marked, labelled: labelled);

List<String> _keys(List<PendingMoment> p) => [for (final m in p) m.key];

void main() {
  group('the setting gates everything', () {
    test('off (no enabledSince): nothing is pending', () {
      final f = _f(marked: [_m('2026-10-07', '09:00')]);
      expect(f.pending(_now), isEmpty);
    });

    test('on, nothing marked: nothing pending', () {
      expect(_f(since: DateTime(2026, 10, 1)).pending(_now), isEmpty);
    });
  });

  group('since enabling', () {
    final since = DateTime(2026, 10, 7, 8, 30, 45);

    test('a moment marked before the switch went on is not pending', () {
      final p = _f(since: since, marked: [
        _m('2026-10-07', '08:00'),
        _m('2026-10-06', '23:59'),
      ]).pending(_now);
      expect(p, isEmpty);
    });

    test('a moment after it is pending', () {
      final p =
          _f(since: since, marked: [_m('2026-10-07', '09:00')]).pending(_now);
      expect(_keys(p), ['2026-10-07 09:00']);
    });

    test('a moment in the SAME MINUTE as enabling counts (minute resolution)',
        () {
      // Moments carry a minute, not a second: 08:30 was marked inside the
      // minute the switch went on at 08:30:45, so it is not "before".
      final p =
          _f(since: since, marked: [_m('2026-10-07', '08:30')]).pending(_now);
      expect(_keys(p), ['2026-10-07 08:30']);
    });

    test('the minute before enabling does not', () {
      final p =
          _f(since: since, marked: [_m('2026-10-07', '08:29')]).pending(_now);
      expect(p, isEmpty);
    });
  });

  group('unlabelled only', () {
    final since = DateTime(2026, 9, 1);

    test('a labelled moment is not pending', () {
      final p = _f(
        since: since,
        marked: [_m('2026-10-06', '10:00'), _m('2026-10-06', '11:00')],
        labelled: {'2026-10-06 10:00'},
      ).pending(_now);
      expect(_keys(p), ['2026-10-06 11:00']);
    });

    test('a skipped moment is answered too (it stays unlabelled, not pending)',
        () {
      // A skip is a MomentLabel row with a null label; its key is in `labelled`.
      final p = _f(
        since: since,
        marked: [_m('2026-10-06', '10:00')],
        labelled: {'2026-10-06 10:00'},
      ).pending(_now);
      expect(p, isEmpty);
    });

    test('a label on another day at the same minute does not hide this one',
        () {
      final p = _f(
        since: since,
        marked: [_m('2026-10-06', '10:00')],
        labelled: {'2026-10-05 10:00'},
      ).pending(_now);
      expect(_keys(p), ['2026-10-06 10:00']);
    });
  });

  group('the 7-day cutoff', () {
    final since = DateTime(2026, 8, 1);

    test('exactly 7 days old (same wall minute) is still pending', () {
      final p =
          _f(since: since, marked: [_m('2026-09-30', '12:00')]).pending(_now);
      expect(_keys(p), ['2026-09-30 12:00']);
    });

    test('a minute older than that stops being pending', () {
      final p =
          _f(since: since, marked: [_m('2026-09-30', '11:59')]).pending(_now);
      expect(p, isEmpty);
    });

    test('older moments are dropped, newer kept, in the same call', () {
      final p = _f(since: since, marked: [
        _m('2026-09-20', '08:00'),
        _m('2026-10-02', '08:00'),
        _m('2026-10-07', '07:00'),
      ]).pending(_now);
      expect(_keys(p), ['2026-10-02 08:00', '2026-10-07 07:00']);
    });

    test('it ages out with the clock: pending until 7 days and a minute', () {
      final f = _f(since: since, marked: [_m('2026-10-02', '08:00')]);
      expect(f.pending(DateTime(2026, 10, 9, 7, 59)), hasLength(1));
      expect(f.pending(DateTime(2026, 10, 9, 8, 0)), hasLength(1));
      expect(f.pending(DateTime(2026, 10, 9, 8, 1)), isEmpty);
    });

    test('DST: 7 wall-clock days, not 168 hours', () {
      // The US fall-back day (2026-11-01) makes 7 wall days 169 hours. With
      // TZ=America/New_York a `Duration(days: 7)` cutoff would drop this one.
      final p = _f(
        since: DateTime(2026, 10, 1),
        marked: [_m('2026-11-01', '12:00')],
      ).pending(DateTime(2026, 11, 8, 12, 0));
      expect(_keys(p), ['2026-11-01 12:00']);
    });
  });

  group('local time and order', () {
    test('local is the wall-clock minute of the stored date and time', () {
      final p = _f(
        since: DateTime(2026, 9, 1),
        marked: [_m('2026-10-06', '23:50')],
      ).pending(DateTime(2026, 10, 7, 0, 5));
      expect(p, hasLength(1));
      // Marked 15 minutes ago, on the PREVIOUS local day: not shifted to UTC,
      // not re-labelled to today.
      expect(p.single.date, '2026-10-06');
      expect(p.single.local, DateTime(2026, 10, 6, 23, 50));
      expect(p.single.local.isUtc, isFalse);
    });

    test('oldest first, whatever order they were stored in', () {
      final p = _f(since: DateTime(2026, 9, 1), marked: [
        _m('2026-10-07', '09:00'),
        _m('2026-10-05', '22:10'),
        _m('2026-10-05', '07:30'),
      ]).pending(_now);
      expect(_keys(p),
          ['2026-10-05 07:30', '2026-10-05 22:10', '2026-10-07 09:00']);
    });

    test('a duplicate (same date and minute) is one moment', () {
      final p = _f(since: DateTime(2026, 9, 1), marked: [
        _m('2026-10-06', '10:00'),
        _m('2026-10-06', '10:00'),
      ]).pending(_now);
      expect(p, hasLength(1));
    });
  });

  group('parseMarked reads the journal tags', () {
    test('takes `moment HH:mm` tags from tags_json, per day', () {
      final got = MomentFollowUps.parseMarked([
        {
          'date': '2026-10-06',
          'tags_json': '["gym","moment 09:15","moment 21:40"]',
          'note': '',
        },
        {'date': '2026-10-07', 'tags_json': '["moment 07:05"]', 'note': 'x'},
      ]);
      expect(got, [
        _m('2026-10-06', '09:15'),
        _m('2026-10-06', '21:40'),
        _m('2026-10-07', '07:05'),
      ]);
    });

    test('ignores look-alike tags, malformed JSON and malformed times', () {
      final got = MomentFollowUps.parseMarked([
        {'date': '2026-10-06', 'tags_json': '["moment","moments 09:15"]'},
        {'date': '2026-10-06', 'tags_json': 'not json'},
        {'date': '2026-10-06', 'tags_json': '["moment 25:99","moment 9:5"]'},
        {'date': '2026-10-06', 'tags_json': '[]'},
        {'date': '2026-10-06', 'tags_json': null},
      ]);
      expect(got, isEmpty);
    });
  });

  test('source guard: no UTC day labels, no 86400, no fixed-length cutoff', () {
    final code =
        codeOnly(File('lib/gestures/moment_follow_ups.dart').readAsStringSync());
    expect(code.contains('toUtc'), isFalse);
    expect(code.contains('86400'), isFalse);
    expect(RegExp(r'Duration\(\s*days').hasMatch(code), isFalse,
        reason: 'day arithmetic must be calendar-based (DST)');
  });
}
