// The Home minute tick across a DST transition.
//
// The tick must be armed from the UTC instant: minute boundaries are the same
// in every whole/half/quarter-hour zone, while local wall-clock construction is
// not — in the repeated fall-back hour `DateTime(y, m, d, h, min + 1)`
// resolves to the FIRST occurrence of that wall time, an hour in the past, so a
// delay of about -59 min became a zero-delay Timer and a setState loop.
//
// The process timezone is moved with libc setenv/tzset (same idiom as
// day_window_dst_test.dart) and restored afterwards. Time is a simulated
// clock; nothing here reads the system clock.

import 'dart:ffi';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

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

dynamic _state(WidgetTester t) => t.state(find.byType(HomeScreen));

Future<void> _pumpHome(WidgetTester t, AppState app) => t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: Scaffold(body: HomeScreen(hour: 1, data: const HomeData())),
      ),
    ));

void main() {
  final originalTz = Platform.environment['TZ'];

  setUp(() {
    if (Platform.isWindows) markTestSkipped('POSIX-only (libc setenv)');
    _setProcessTz('America/Denver');
  });
  tearDown(() => _setProcessTz(originalTz));

  group('nextMinuteTickDelay', () {
    test('fall back 2026-11-01, second 01:30:30 MST (08:30:30Z): 30 s', () {
      final now = DateTime.utc(2026, 11, 1, 8, 30, 30).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 30));
    });

    test('every second of the repeated hour waits (0, 60 s]', () {
      final start = DateTime.utc(2026, 11, 1, 7, 55);
      for (var s = 0; s < 15 * 60; s += 7) {
        final now = start.add(Duration(seconds: s)).toLocal();
        final d = nextMinuteTickDelay(now);
        expect(d > Duration.zero, isTrue, reason: '$now -> $d');
        expect(d <= const Duration(seconds: 60), isTrue, reason: '$now -> $d');
      }
    });

    test('on a whole minute the next tick is a full minute away', () {
      final now = DateTime.utc(2026, 11, 1, 8, 30).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 60));
    });

    test('one millisecond before the boundary', () {
      final now = DateTime.utc(2026, 11, 1, 8, 30, 59, 999).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(milliseconds: 1));
    });

    test('spring forward 2026-03-08: 01:59:30 MST (08:59:30Z) is 30 s', () {
      final now = DateTime.utc(2026, 3, 8, 8, 59, 30).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 30));
    });

    test('spring forward: the first MDT second waits a full minute', () {
      final now = DateTime.utc(2026, 3, 8, 9, 0).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 60));
    });

    test('a half-hour zone has the same minute boundaries', () {
      _setProcessTz('Asia/Kolkata');
      final now = DateTime.utc(2026, 11, 1, 8, 30, 45).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 15));
    });
  });

  group('the armed tick, through HomeScreen', () {
    Future<void> across(
      WidgetTester t,
      DateTime startUtc, {
      required int minutes,
    }) async {
      var fake = startUtc.toLocal();
      await withClock(Clock(() => fake), () async {
        final app = AppState.forTesting();
        addTearDown(app.dispose);
        await _pumpHome(t, app);

        // Armed to the next minute boundary, never zero or negative. Asserted
        // BEFORE any time passes: a zero-delay loop would never return.
        final armed = _state(t).debugLastTickDelay as Duration;
        expect(armed > Duration.zero, isTrue, reason: 'armed $armed');
        expect(armed <= const Duration(seconds: 60), isTrue,
            reason: 'armed $armed');

        // The clock and the timers advance together, ten simulated seconds at
        // a time, and ticks are counted per whole simulated minute.
        var last = _state(t).debugTickCount as int;
        for (var m = 0; m < minutes; m++) {
          for (var i = 0; i < 6; i++) {
            fake = fake.add(const Duration(seconds: 10));
            await t.pump(const Duration(seconds: 10));
          }
          final now = _state(t).debugTickCount as int;
          expect(now - last, lessThanOrEqualTo(1),
              reason: 'minute $m ($fake): ${now - last} ticks');
          last = now;
        }
        // And it kept ticking: roughly once a minute, not stalled.
        expect(last, greaterThanOrEqualTo(minutes - 1));
      });
    }

    testWidgets('the first armed delay at 08:30:30Z on fall-back day is 30 s',
        (t) async {
      var fake = DateTime.utc(2026, 11, 1, 8, 30, 30).toLocal();
      await withClock(Clock(() => fake), () async {
        final app = AppState.forTesting();
        addTearDown(app.dispose);
        await _pumpHome(t, app);
        expect(_state(t).debugLastTickDelay, const Duration(seconds: 30));
        fake = fake.add(const Duration(seconds: 30));
        await t.pump(const Duration(seconds: 30));
        expect(_state(t).debugTickCount, 1);
        expect(_state(t).debugLastTickDelay, const Duration(seconds: 60));
      });
    });

    testWidgets('at most one tick per minute across the whole fall-back hour',
        (t) async {
      await across(t, DateTime.utc(2026, 11, 1, 7, 30, 30), minutes: 150);
    });

    testWidgets('at most one tick per minute across spring-forward',
        (t) async {
      await across(t, DateTime.utc(2026, 3, 8, 8, 30, 30), minutes: 150);
    });
  });
}
