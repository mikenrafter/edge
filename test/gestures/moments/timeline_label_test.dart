// The day timeline shows the label on the moment.
//
// A marked moment has a real clock (the minute the tap happened), so a LABELLED
// one is placed on the day at that local minute. A skipped moment has nothing
// to show. The time is built from the local calendar fields (DST-safe), never
// from a day start plus minutes.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';

import '../../support/dart_source_lexical.dart';

final int _day = DateTime(2026, 10, 6).millisecondsSinceEpoch ~/ 1000;
int _at(int h, [int m = 0]) =>
    DateTime(2026, 10, 6, h, m).millisecondsSinceEpoch ~/ 1000;

MomentLabel _l(String hhmm, String? label, {String? note}) => MomentLabel(
    date: '2026-10-06',
    hhmm: hhmm,
    label: label,
    note: note,
    answeredAtMs: 1);

void main() {
  test('a labelled moment sits on the day at its minute, titled by the label',
      () {
    final m = dayMoments(
      timeline: {'day_start': _day},
      momentLabels: [_l('10:15', 'nap')],
    );
    expect(m, hasLength(1));
    expect(m.single.at, _at(10, 15));
    expect(m.single.title, contains('Nap'));
  });

  test('"Pills & meds" reads as written, and the note rides along', () {
    final m = dayMoments(
      timeline: {'day_start': _day},
      momentLabels: [
        _l('08:00', 'pills_meds'),
        _l('09:00', 'other', note: 'felt dizzy'),
      ],
    );
    expect(m[0].title, contains('Pills & meds'));
    expect(m[1].title, contains('Other'));
    expect(m[1].detail, contains('felt dizzy'));
    expect(m[0].detail, contains('08:00'));
  });

  test('a skipped moment has no line', () {
    final m = dayMoments(
      timeline: {'day_start': _day},
      momentLabels: [_l('10:15', null)],
    );
    expect(m, isEmpty);
  });

  test('an unknown label id (from a newer build) is not invented into text',
      () {
    final m = dayMoments(
      timeline: {'day_start': _day},
      momentLabels: [_l('10:15', 'teleport')],
    );
    expect(m, isEmpty);
  });

  test('it is ordered with everything else by time', () {
    final m = dayMoments(
      timeline: {
        'day_start': _day,
        'naps': [
          {'start': _at(14), 'end': _at(14, 40), 'duration_min': 40},
        ],
        'sessions': [
          {'start_ts': _at(7), 'end_ts': _at(8), 'type': 'run'},
        ],
      },
      momentLabels: [_l('10:15', 'meal')],
    );
    expect([for (final x in m) x.at], [_at(7), _at(10, 15), _at(14)]);
  });

  test('a labelled moment does not become a nap window or a session', () {
    final m = dayMoments(
      timeline: {'day_start': _day},
      momentLabels: [_l('10:15', 'nap')],
    );
    expect(m.single.until, isNull, reason: 'an instant, not a fabricated span');
  });

  test('the timeline screen loads the labels for the day it shows', () {
    final code =
        codeOnly(File('lib/ui2/screens/day_timeline.dart').readAsStringSync());
    expect(code.contains('LocalDb.momentLabels('), isTrue);
    expect(code.contains('momentLabels:'), isTrue);
  });
}
