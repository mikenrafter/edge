// 8B — Live devices: a RAM-only 30 s ring buffer per (device, stream) and a
// screen that draws one graph per stream per connected device.
// See test/phase8/CONTRACTS.md §8B.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:openstrap_edge/ui2/profile/live_devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/dart_source_lexical.dart';

final _t0 = DateTime(2026, 10, 2, 9, 0, 0);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

void main() {
  group('live chart slots follow the stream rate', () {
    const window = Duration(seconds: 30);
    final now = _at(30000);

    test('a 1 Hz stream (with jitter) has no empty slot between readings', () {
      final samples = [
        for (var i = 0; i < 30; i++)
          LiveSample(_at(i * 1000 + (i.isEven ? 120 : -90) + 500), 60.0 + i),
      ];
      final slots = liveSlotsFor(samples, window);
      expect(slots, 20);
      final series = liveSeries(samples, now, window, slots: slots);
      expect(series.where((v) => v == null), isEmpty);
      expect(liveSlotWidth(window, slots), '1.5 s');
    });

    test('a real silence is still a gap', () {
      final samples = [
        for (var i = 0; i < 30; i++)
          if (i < 10 || i >= 20) LiveSample(_at(i * 1000 + 500), 60.0),
      ];
      final series =
          liveSeries(samples, now, window, slots: liveSlotsFor(samples, window));
      expect(series.where((v) => v == null), isNotEmpty);
    });

    test('a fast stream keeps 60 half-second slots', () {
      final samples = [
        for (var i = 0; i < 300; i++) LiveSample(_at(i * 100), 0.1),
      ];
      expect(liveSlotsFor(samples, window), 60);
      expect(liveSlotWidth(window, 60), '½ s');
    });
  });

  group('LiveStreamBuffer', () {
    test('the window is 30 s by default', () {
      expect(LiveStreamBuffer().window, const Duration(seconds: 30));
    });

    test('a sample is visible up to 30 s old and gone at exactly 30 s', () {
      final b = LiveStreamBuffer()..add('band', 'hr', _at(0), 60);
      expect(b.samples('band', 'hr', now: _at(29999)).map((s) => s.value), [60]);
      expect(b.samples('band', 'hr', now: _at(30000)), isEmpty);
    });

    test('adding evicts what fell out of the window (memory stays bounded)',
        () {
      final b = LiveStreamBuffer()
        ..add('band', 'hr', _at(0), 60)
        ..add('band', 'hr', _at(29999), 61);
      expect(b.retained('band', 'hr'), hasLength(2));
      b.add('band', 'hr', _at(30000), 62);
      expect(b.retained('band', 'hr').map((s) => s.value), [61, 62]);
    });

    test('an out-of-order sample is dropped', () {
      final b = LiveStreamBuffer();
      expect(b.add('band', 'hr', _at(1000), 60), isTrue);
      expect(b.add('band', 'hr', _at(500), 99), isFalse);
      expect(b.retained('band', 'hr').map((s) => s.value), [60]);
      expect(b.add('band', 'hr', _at(1500), 61), isTrue);
    });

    test('ordering is per stream: another stream is unaffected', () {
      final b = LiveStreamBuffer()..add('band', 'hr', _at(1000), 60);
      expect(b.add('band', 'accel_x', _at(500), 0.1), isTrue);
      expect(b.add('strap', 'hr', _at(500), 70), isTrue);
    });

    test('stream keys appear as they are reported, per device, in order', () {
      final b = LiveStreamBuffer()
        ..add('band', 'hr', _at(0), 60)
        ..add('band', 'accel_x', _at(0), 0.1)
        ..add('polar', 'rr', _at(0), 812)
        ..add('band', 'a_stream_nobody_planned_for', _at(0), 1);
      expect(b.streamKeys('band'),
          ['hr', 'accel_x', 'a_stream_nobody_planned_for']);
      expect(b.streamKeys('polar'), ['rr']);
      expect(b.streamKeys('nobody'), isEmpty);
      expect(b.deviceIds, containsAll(['band', 'polar']));
    });

    test('a stream whose samples all aged out keeps its key (shown as empty)',
        () {
      final b = LiveStreamBuffer()..add('band', 'skin_temp', _at(0), 33.1);
      expect(b.streamKeys('band'), ['skin_temp']);
      expect(b.samples('band', 'skin_temp', now: _at(60000)), isEmpty);
    });

    test('clear drops everything', () {
      final b = LiveStreamBuffer()..add('band', 'hr', _at(0), 60);
      b.clear();
      expect(b.deviceIds, isEmpty);
    });
  });

  group('LiveDevicesView', () {
    final now = _at(40000);
    LiveStreamBuffer buffer() => LiveStreamBuffer()
      ..add('band', 'hr', _at(20000), 61)
      ..add('band', 'hr', _at(30000), 63)
      ..add('band', 'accel_x', _at(25000), 0.02)
      ..add('band', 'accel_x', _at(35000), -0.01)
      ..add('band', 'skin_temp', _at(1000), 33.4) // 39 s old: out of window
      ..add('band', 'novel_stream', _at(38000), 5)
      ..add('band', 'novel_stream', _at(39000), 6)
      ..add('polar', 'hr', _at(36000), 120)
      ..add('polar', 'hr', _at(37000), 121);

    final devices = [
      const LiveDevice(
          id: 'band',
          name: 'Synthetic band',
          kind: 'WHOOP 4.0',
          connected: true,
          batteryPct: 78),
      LiveDevice(
          id: 'polar',
          name: 'Polar H10',
          kind: 'Chest strap',
          connected: false,
          lastSeen: _at(37000)),
    ];

    Future<void> pump(WidgetTester t) async {
      t.view.physicalSize = const Size(1170, 15000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: LiveDevicesView(devices: devices, buffer: buffer(), now: now),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('one card per device with name and kind', (t) async {
      await pump(t);
      expect(find.text('Synthetic band'), findsOneWidget);
      expect(find.text('Polar H10'), findsOneWidget);
      expect(find.textContaining('WHOOP 4.0'), findsWidgets);
      expect(find.textContaining('78%'), findsOneWidget);
    });

    testWidgets('one graph per stream with data; novel keys need no UI change',
        (t) async {
      await pump(t);
      // band: hr, accel_x, novel_stream have data; skin_temp does not.
      expect(find.byType(LiveStreamChart), findsNWidgets(3));
      // The sensors list (8AI G6) names every stream too, so look in the graph.
      expect(
          find.descendant(
              of: find.byType(LiveStreamChart),
              matching: find.text(liveStreamLabel('novel_stream'))),
          findsOneWidget);
      expect(liveStreamLabel('novel_stream'), 'novel_stream',
          reason: 'an unknown key is shown as-is');
      expect(liveStreamLabel('hr'), isNot('hr'),
          reason: 'known keys get a human label');
    });

    testWidgets('an empty stream says so instead of a flat line', (t) async {
      await pump(t);
      // Named once in the sensors list (8AI G6) and once over its empty note.
      expect(find.text(liveStreamLabel('skin_temp')), findsNWidgets(2));
      expect(find.text('No data in the last 30 s'), findsOneWidget);
    });

    testWidgets('a disconnected device shows last seen and no chart',
        (t) async {
      await pump(t);
      expect(find.textContaining('Last seen'), findsOneWidget);
      // Polar still has in-window hr samples; drawing them would make four.
      expect(find.byType(LiveStreamChart), findsNWidgets(3));
      expect(find.text('No data in the last 30 s'), findsOneWidget,
          reason: 'a disconnected device is not an empty stream either');
    });

    testWidgets('every graph is scrubbable (8F)', (t) async {
      await pump(t);
      for (final chart in find.byType(LiveStreamChart).evaluate()) {
        expect(
            find.descendant(
                of: find.byWidget(chart.widget),
                matching: find.byType(ChartScrub)),
            findsOneWidget);
      }
    });

    testWidgets('no connected device: an honest empty state', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: LiveDevicesView(
            devices: const [], buffer: LiveStreamBuffer(), now: now),
      ));
      await t.pumpAndSettle();
      expect(find.byType(LiveStreamChart), findsNothing);
      expect(find.textContaining('No device'), findsOneWidget);
    });
  });

  group('invariant 14: live streams stay in RAM', () {
    test('the buffer imports no storage', () {
      final src = File('lib/state/live_stream_buffer.dart').readAsStringSync();
      final imports = [
        for (final m in RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
                multiLine: true)
            .allMatches(src))
          m.group(1)!,
      ];
      for (final banned in [
        'db.dart',
        'sqflite',
        'shared_preferences',
        'path_provider',
        'dart:io',
      ]) {
        expect(imports.where((u) => u.contains(banned)), isEmpty,
            reason: banned);
      }
      expect(codeOnly(src), isNot(contains('LocalDb')));
    });

    test('AppState owns one buffer, fed from the live callbacks', () {
      final src = codeOnly(File('lib/state/app_state.dart').readAsStringSync());
      expect(src, contains('LiveStreamBuffer('));
      expect(src, contains('liveStreams'));
    });

    test('the screen has a route wrapper that reads AppState', () {
      final src = File('lib/ui2/profile/live_devices.dart').readAsStringSync();
      expect(codeOnly(src), contains('class LiveDevices '));
    });
  });
}
