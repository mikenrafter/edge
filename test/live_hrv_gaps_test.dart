// The live "Beat intervals (ms)" graph has gaps only
// where beats really stopped.
//
// USER REPORT (APK f88d230c): "the live HRV data had a lot of gaps". The graph
// drew broken segments and a "Not recorded" key while beats were arriving.
//
// ROOT CAUSES, both reproduced here:
//   * Stamping. AppState._bufferLiveRr stamped each frame's newest beat at
//     arrival and placed the earlier beats back by the intervals after them.
//     A frame that arrives soon after another (BLE batches them) puts its
//     earlier beats BEFORE the previous frame's newest, and LiveStreamBuffer.add
//     refuses anything older than the newest sample: those beats were dropped.
//     (The frame's own ts is whole seconds and repeats across a session, so it
//     is no finer than arrival; it is not used.)
//   * Gap rule. The graph resampled a beat stream into fixed slots and called
//     every empty slot a gap, so ordinary beat-to-beat jitter between slots
//     broke the line. A stream with one sample per EVENT breaks only where no
//     beat came for max(3 s, 3 x the recent median interval).
//
// ASSUMED API:
//   * stampLiveBeats(arrival, rrMs, after:) in lib/state/live_stream_buffer.dart:
//     one stamp per beat, oldest first, the newest at arrival when it can be,
//     each strictly after [after] (the previous beat) and after the one before
//     it in the frame.
//   * liveEventSeries(samples, now, window) in live_devices.dart ->
//     LiveEventSeries(drawn, read): [drawn] is the line (null only inside a real
//     gap or outside the first..last beat), [read] has a value only in a slot
//     that holds a beat (what a scrub may quote).
//   * LiveStreamChart(event: true) for event streams; kLiveEventStreams names
//     them ('rr').

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:openstrap_edge/ui2/profile/live_devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/live_stream_band_rig.dart';

const _window = Duration(seconds: 30);
final _now = DateTime(2026, 10, 4, 12, 0, 30);

LiveSample _ago(double s) => LiveSample(
    _now.subtract(Duration(milliseconds: (s * 1000).round())), 800);

/// Beats [rr] ms apart, ending [endAgo] before [_now].
List<LiveSample> _beats(List<int> rr, {Duration endAgo = Duration.zero}) {
  var at = _now.subtract(endAgo);
  final out = <LiveSample>[];
  for (var i = rr.length - 1; i >= 0; i--) {
    out.add(LiveSample(at, rr[i].toDouble()));
    at = at.subtract(Duration(milliseconds: rr[i]));
  }
  return out.reversed.toList();
}

bool _hole(List<double?> s) {
  final first = s.indexWhere((v) => v != null);
  final last = s.lastIndexWhere((v) => v != null);
  return first >= 0 && s.sublist(first, last + 1).contains(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('stamping', () {
    test('stampLiveBeats: strictly increasing, newest at arrival', () {
      final a = DateTime(2026, 10, 4, 12);
      final s = stampLiveBeats(a, const [800, 810, 790]);
      expect(s, hasLength(3));
      expect(s.last, a);
      for (var i = 1; i < s.length; i++) {
        expect(s[i].isAfter(s[i - 1]), isTrue);
      }
    });

    test('a frame landing right after another starts after that frame\'s '
        'newest beat, never before it', () {
      final a = DateTime(2026, 10, 4, 12);
      final first = stampLiveBeats(a, const [800, 810]);
      final second = stampLiveBeats(a.add(const Duration(milliseconds: 40)),
          const [790, 800, 805],
          after: first.last);
      expect(second.first.isAfter(first.last), isTrue);
      for (var i = 1; i < second.length; i++) {
        expect(second[i].isAfter(second[i - 1]), isTrue);
      }
    });

    test('with nothing before it, beats sit one interval apart', () {
      final a = DateTime(2026, 10, 4, 12);
      final s = stampLiveBeats(a, const [800, 900]);
      expect(s[1].difference(s[0]), const Duration(milliseconds: 900));
    });

    test('batched frames with the same arrival lose no beat', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(hr28Inner(hr: 62, rr: [800, 810]));
      rig.feed(hr28Inner(hr: 62, rr: [790, 800, 805]));
      rig.feed(hr28Inner(hr: 62, rr: [820, 780]));
      expect(rig.values('rr'),
          [800, 810, 790, 800, 805, 820, 780].map((v) => v.toDouble()).toList());
      final at = [
        for (final s in rig.app.liveStreams.retained(kBandId, 'rr')) s.at
      ];
      for (var i = 1; i < at.length; i++) {
        expect(at[i].isAfter(at[i - 1]), isTrue,
            reason: 'beat $i has its own, later time');
      }
    });
  });

  group('the line', () {
    test('normal beats, jittering 450..1400 ms, draw one unbroken line', () {
      final rr = [
        for (var i = 0; i < 40; i++) 450 + (i * 337) % 950,
      ];
      // Keep what fits the window.
      var sum = 0;
      final kept = <int>[];
      for (final v in rr.reversed) {
        if (sum + v > 29000) break;
        sum += v;
        kept.insert(0, v);
      }
      final e = liveEventSeries(_beats(kept), _now, _window);
      expect(_hole(e.drawn), isFalse, reason: 'beats were arriving all along');
      expect(hasChartGaps([_trim(e.drawn)]), isFalse);
    });

    test('a fixed slot grid would have broken it: 1.4 s beats at 60 slots', () {
      final e = liveEventSeries(_beats(List.filled(20, 1400)), _now, _window);
      expect(_hole(e.drawn), isFalse);
    });

    test('a real hole (no beat for 8 s at ~0.8 s beats) is a gap', () {
      final before = _beats(List.filled(8, 800), endAgo: const Duration(seconds: 16));
      final after = _beats(List.filled(8, 800));
      final e = liveEventSeries([...before, ...after], _now, _window);
      expect(_hole(e.drawn), isTrue);
      expect(hasChartGaps([_trim(e.drawn)]), isTrue);
      // The hole's middle is null, not interpolated across.
      final mid = e.drawn.length ~/ 2;
      expect(e.drawn[mid], isNull);
    });

    test('3 s is the floor: a 2.9 s pause at 0.6 s beats is no gap, 3.5 s is',
        () {
      // Beats every 0.6 s except for one pause, [pause] seconds long.
      List<LiveSample> withPause(double pause) {
        final out = <LiveSample>[];
        var t = 25.0; // seconds ago, counting down to now
        for (var i = 0; i < 5; i++) {
          out.add(_ago(t));
          t -= 0.6;
        }
        t -= pause - 0.6;
        while (t >= 0) {
          out.add(_ago(t));
          t -= 0.6;
        }
        return out;
      }

      expect(_hole(liveEventSeries(withPause(2.9), _now, _window).drawn),
          isFalse);
      expect(_hole(liveEventSeries(withPause(3.5), _now, _window).drawn),
          isTrue);
    });

    test('slow beats widen the allowance: 2 s beats, a 5 s pause is no gap, '
        'a 7 s pause is', () {
      List<LiveSample> withPause(double pause) => [
            for (final t in [25.0, 23.0, 21.0, 19.0]) _ago(t),
            for (var t = 19.0 - pause; t >= 0; t -= 2.0) _ago(t),
          ];
      expect(_hole(liveEventSeries(withPause(5), _now, _window).drawn), isFalse);
      expect(_hole(liveEventSeries(withPause(7), _now, _window).drawn), isTrue);
    });

    test('a quiet stream stops its line (no beat for 10 s is never drawn as '
        'continuing)', () {
      final e = liveEventSeries(
          _beats(List.filled(10, 800), endAgo: const Duration(seconds: 12)),
          _now,
          _window);
      expect(e.drawn.last, isNull);
      expect(e.drawn.where((v) => v != null), isNotEmpty);
    });

    test('read holds a value only where a beat is', () {
      final e = liveEventSeries(_beats(List.filled(10, 1400)), _now, _window);
      final beats = e.read.whereType<double>().length;
      expect(beats, inInclusiveRange(9, 10));
      expect(e.drawn.whereType<double>().length, greaterThan(beats),
          reason: 'the line joins the beats; the scrub quotes only beats');
    });

    test('fewer than two beats: nothing to join, nothing invented', () {
      final one = liveEventSeries(_beats([800]), _now, _window);
      expect(one.drawn.whereType<double>(), hasLength(1));
      expect(liveEventSeries(const [], _now, _window).drawn,
          everyElement(isNull));
    });
  });

  group('the chart', () {
    Future<void> pump(WidgetTester t, List<LiveSample> s,
        {bool event = true}) async {
      t.view.physicalSize = const Size(1170, 3000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
            body: LiveStreamChart(
                label: 'Beat intervals (ms)',
                samples: s,
                now: _now,
                window: _window,
                event: event)),
      ));
      await t.pump();
    }

    testWidgets('steady beats: no "Not recorded" key', (t) async {
      await pump(t, _beats([for (var i = 0; i < 30; i++) 900 + (i % 5) * 60]));
      expect(find.text('Not recorded'), findsNothing);
    });

    testWidgets('a real hole: "Not recorded" is there', (t) async {
      final before = _beats(List.filled(8, 800), endAgo: const Duration(seconds: 16));
      final after = _beats(List.filled(8, 800));
      await pump(t, [...before, ...after]);
      expect(find.text('Not recorded'), findsOneWidget);
    });

    testWidgets('the screen asks for the event rule for rr only', (t) async {
      expect(kLiveEventStreams, contains('rr'));
      expect(kLiveEventStreams, isNot(contains('hr')));
    });
  });
}

List<double?> _trim(List<double?> s) {
  final first = s.indexWhere((v) => v != null);
  final last = s.lastIndexWhere((v) => v != null);
  return first < 0 ? const [] : s.sublist(first, last + 1);
}
