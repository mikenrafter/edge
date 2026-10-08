// Tasker export of a review: data only, one broadcast per item (a range is one
// item), on Save only, connection off => nothing. The Dart payload and the
// channel call are pinned here; NativeChannels.kt's `emit_event` copies the
// extras into the Android broadcast (Kotlin: untestable here; it needs a
// `Double` case). RED: stubs throw / the rate limit is still on.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/platform/tasker_bridge.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _start = DateTime(2026, 10, 6, 9, 15);
final _end = DateTime(2026, 10, 6, 10, 5);
int _s(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('payload', () {
    test('a plain moment: kind, type, start, day. No end, no value', () {
      final p = TaskerMomentExport.payloadFor(
          ReviewedItem(choice: MomentChoice.meal, start: _start));
      expect(p, {
        'kind': 'moment',
        'type': 'meal',
        'start': _s(_start),
        'day': '2026-10-06',
      });
      expect(p.containsKey('end'), isFalse);
      expect(p.containsKey('value'), isFalse);
    });

    test('a typed dose rides as a double', () {
      final p = TaskerMomentExport.payloadFor(ReviewedItem(
          choice: MomentChoice.caffeine, start: _start, value: 80));
      expect(p['value'], 80.0);
      expect(p['value'], isA<double>());
      expect(p['type'], 'caffeine');
    });

    test('a range is one item with start AND end', () {
      final p = TaskerMomentExport.payloadFor(
          ReviewedItem(choice: MomentChoice.nap, start: _start, end: _end));
      expect(p, {
        'kind': 'range',
        'type': 'nap',
        'start': _s(_start),
        'end': _s(_end),
        'day': '2026-10-06',
      });
    });

    test('the day is the START\'s local day, even for a range over midnight',
        () {
      final p = TaskerMomentExport.payloadFor(ReviewedItem(
          choice: MomentChoice.workout,
          start: DateTime(2026, 10, 5, 23, 40),
          end: DateTime(2026, 10, 6, 0, 50)));
      expect(p['day'], '2026-10-05');
      expect(p['end'], _s(DateTime(2026, 10, 6, 0, 50)));
    });

    test('only wire-safe types: String, int, double', () {
      final p = TaskerMomentExport.payloadFor(ReviewedItem(
          choice: MomentChoice.alcohol, start: _start, value: 1.5));
      for (final v in p.values) {
        expect(v is String || v is int || v is double, isTrue, reason: '$v');
      }
    });
  });

  group('sending', () {
    test('one broadcast per item, in order, under the one event name', () async {
      final sent = <(String, Map<String, Object>)>[];
      final x = TaskerMomentExport(
          connectionOn: () => true,
          emit: (e, extras) async {
            sent.add((e, extras));
            return true;
          });
      await x.exportAll([
        ReviewedItem(choice: MomentChoice.meal, start: _start),
        ReviewedItem(choice: MomentChoice.nap, start: _start, end: _end),
        ReviewedItem(choice: MomentChoice.caffeine, start: _end, value: 80),
      ]);
      expect(sent.map((e) => e.$1).toSet(), {'MOMENT_REVIEWED'});
      expect(TaskerMomentExport.event, 'MOMENT_REVIEWED');
      expect(sent.map((e) => e.$2['type']), ['meal', 'nap', 'caffeine']);
      expect(sent.map((e) => e.$2['kind']), ['moment', 'range', 'moment']);
    });

    test('connection off: nothing is sent', () async {
      var calls = 0;
      final x = TaskerMomentExport(
          connectionOn: () => false,
          emit: (e, extras) async {
            calls++;
            return true;
          });
      await x.exportAll([ReviewedItem(choice: MomentChoice.meal, start: _start)]);
      expect(calls, 0);
    });

    test('the connection is read at send time, not at construction', () async {
      var on = false;
      var calls = 0;
      final x = TaskerMomentExport(
          connectionOn: () => on,
          emit: (e, extras) async {
            calls++;
            return true;
          });
      on = true;
      await x.exportAll([ReviewedItem(choice: MomentChoice.meal, start: _start)]);
      expect(calls, 1);
    });

    test('a throwing or false broadcast does not stop the next, and never throws',
        () async {
      final types = <Object?>[];
      final x = TaskerMomentExport(
          connectionOn: () => true,
          emit: (e, extras) async {
            types.add(extras['type']);
            if (extras['type'] == 'meal') throw StateError('channel gone');
            return false;
          });
      await x.exportAll([
        ReviewedItem(choice: MomentChoice.meal, start: _start),
        ReviewedItem(choice: MomentChoice.nap, start: _start, end: _end),
      ]);
      expect(types, ['meal', 'nap']);
    });

    test('no items: no broadcast', () async {
      var calls = 0;
      await TaskerMomentExport(
          connectionOn: () => true,
          emit: (e, extras) async {
            calls++;
            return true;
          }).exportAll(const []);
      expect(calls, 0);
    });
  });

  group('default path: the real channel call', () {
    const channel = MethodChannel('openstrap/tasker');
    final calls = <MethodCall>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      Prefs.setBool(Prefs.taskerConnection, true);
      calls.clear();
      TaskerBridge.debugAndroidOverride = true;
      TaskerBridge.debugResetRateLimit();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        return true;
      });
    });

    tearDown(() {
      TaskerBridge.debugAndroidOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('emit_event on openstrap/tasker with the event and the extras',
        () async {
      await TaskerMomentExport().exportAll([
        ReviewedItem(choice: MomentChoice.caffeine, start: _start, value: 80)
      ]);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'emit_event');
      final args = Map<String, Object?>.from(calls.single.arguments as Map);
      expect(args['event'], 'MOMENT_REVIEWED');
      expect(Map<String, Object?>.from(args['extras'] as Map), {
        'kind': 'moment',
        'type': 'caffeine',
        'start': _s(_start),
        'day': '2026-10-06',
        'value': 80.0,
      });
    });

    test('several items in a row are NOT swallowed by the 60 s sync rate limit',
        () async {
      await TaskerMomentExport().exportAll([
        ReviewedItem(choice: MomentChoice.meal, start: _start),
        ReviewedItem(choice: MomentChoice.nap, start: _start, end: _end),
        ReviewedItem(choice: MomentChoice.workout, start: _start, end: _end),
      ]);
      expect(calls, hasLength(3));
    });

    test('the review does not use up the sync event\'s rate-limit slot',
        () async {
      await TaskerMomentExport().exportAll(
          [ReviewedItem(choice: MomentChoice.meal, start: _start)]);
      calls.clear();
      final ok = await TaskerBridge.emitSyncComplete(records: 3);
      expect(ok, isTrue);
      expect(calls.single.method, 'emit_event');
    });

    test('Prefs "Tasker connection" off: the channel is never called', () async {
      Prefs.setBool(Prefs.taskerConnection, false);
      await TaskerMomentExport().exportAll(
          [ReviewedItem(choice: MomentChoice.meal, start: _start)]);
      expect(calls, isEmpty);
    });

    test('not Android: nothing is sent (iOS has no such broadcast)', () async {
      TaskerBridge.debugAndroidOverride = false;
      await TaskerMomentExport().exportAll(
          [ReviewedItem(choice: MomentChoice.meal, start: _start)]);
      expect(calls, isEmpty);
    });
  });
}
