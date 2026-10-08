// A timed journal field is stored as a WALL-CLOCK minute of its local day, so
// its instant is built from calendar fields, never from "midnight + minutes of
// elapsed time". On a 23 h spring-forward day the elapsed sum lands an hour
// LATE (America/Denver 2026-03-08 23:30 became 2026-03-09 00:30, on the next
// day); on a 25 h fall-back day it lands an hour EARLY.
//
// The host is not in a DST zone, so the process timezone is moved with libc
// setenv("TZ") + tzset(), exactly as day_window_dst_test.dart does (Dart reads
// the C library's local time on every call). POSIX only. No clock is read.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/explorer_annotations.dart';

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void _setProcessTz(String? tz) {
  final lib = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8();
  try {
    if (tz == null) {
      lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv')(key);
    } else {
      final value = tz.toNativeUtf8();
      lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv')(key, value, 1);
      calloc.free(value);
    }
    lib.lookupFunction<_TzsetNative, _TzsetDart>('tzset')();
  } finally {
    calloc.free(key);
  }
}

/// America/Denver: 2026-03-08 springs forward (23 h), 2026-11-01 falls back
/// (25 h).
const _spring = '2026-03-08';
const _fall = '2026-11-01';

int _epoch(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

/// What `getDayTimeline` carries for the day: its real local midnight.
Map<String, dynamic> _timeline(String day) =>
    {'day_start': localDayStartSec(day)};

const _skip = 'POSIX setenv/tzset only';

void main() {
  final originalTz = Platform.environment['TZ'];
  setUpAll(() => _setProcessTz('America/Denver'));
  tearDownAll(() => _setProcessTz(originalTz));

  test('the fixture timezone really applied (guards the whole file)', () {
    expect(DateTime(2026, 3, 8).timeZoneOffset, const Duration(hours: -7));
    expect(localDayLengthSec(_spring), 23 * 3600);
    expect(localDayLengthSec(_fall), 25 * 3600);
  }, skip: Platform.isWindows ? _skip : null);

  group('dayMoments places a timed journal field on its wall-clock minute', () {
    List<Moment> moments(String day, int minuteOfDay) => dayMoments(
          timeline: _timeline(day),
          journal: {
            'caffeine_mg': JournalMetricValue(80, atMinuteOfDay: minuteOfDay),
          },
          fields: kJournalFields,
        );

    test('spring forward: 23:30 stays on 03-08', () {
      final m = moments(_spring, 23 * 60 + 30).single;
      expect(m.at, _epoch(2026, 3, 8, 23, 30));
      expect(DateTime.fromMillisecondsSinceEpoch(m.at * 1000).day, 8,
          reason: 'it slipped onto the next day');
    });

    test('spring forward: a morning minute before the jump is not moved', () {
      expect(moments(_spring, 6 * 60).single.at, _epoch(2026, 3, 8, 6, 0));
    });

    test('fall back: 23:30 is 23:30, not 22:30', () {
      final m = moments(_fall, 23 * 60 + 30).single;
      expect(m.at, _epoch(2026, 11, 1, 23, 30));
      expect(DateTime.fromMillisecondsSinceEpoch(m.at * 1000).hour, 23);
    });

    test('fall back: 06:00 after the repeated hour is 06:00', () {
      expect(moments(_fall, 6 * 60).single.at, _epoch(2026, 11, 1, 6, 0));
    });

    test('an ordinary day is unchanged', () {
      expect(moments('2026-06-15', 13 * 60 + 5).single.at,
          _epoch(2026, 6, 15, 13, 5));
    });
  }, skip: Platform.isWindows ? _skip : null);

  group('rangeAnnotations carries the same instant to the chart', () {
    int at(String day, int minuteOfDay) => rangeAnnotations(
          from: day,
          to: day,
          journalByDay: {
            day: {
              'caffeine_mg': JournalMetricValue(80, atMinuteOfDay: minuteOfDay),
            },
          },
        ).single.at.round();

    test('spring forward 23:30', () {
      expect(at(_spring, 23 * 60 + 30), _epoch(2026, 3, 8, 23, 30));
    });

    test('fall back 23:30', () {
      expect(at(_fall, 23 * 60 + 30), _epoch(2026, 11, 1, 23, 30));
    });
  }, skip: Platform.isWindows ? _skip : null);
}
