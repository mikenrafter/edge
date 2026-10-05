import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/dart_source_lexical.dart';

BuzzSequence _held(List<int> offsets, List<int> durations) =>
    Function.apply(BuzzSequence.new, [offsets], {#durationsMs: durations})
        as BuzzSequence;

void main() {
  test('duration JSON preserves short and long presses and legacy lists', () {
    final s = _held([0, 900], [750, 80]);
    final encoded = {
      'offsetsMs': [0, 900],
      'durationsMs': [750, 80],
    };
    expect(s.toJson(), encoded);
    expect(BuzzSequence.fromJson(jsonDecode(jsonEncode(encoded))), s);
    expect(BuzzSequence([0, 900]).toJson(), [0, 900]);
    expect(s, isNot(_held([0, 900], [80, 80])));
    expect(() => (s as dynamic).durationsMs.add(1), throwsUnsupportedError);
  });

  test('duration JSON rejects incomplete and invalid durations', () {
    for (final durations in [
      [80],
      [-1, 80],
      [80.5, 80],
    ]) {
      expect(
        () => BuzzSequence.fromJson({
          'offsetsMs': [0, 900],
          'durationsMs': durations,
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'long presses use the release gap rather than a limit on start offsets',
    () {
      final s = _held([0, 3100], [3000, 80]);
      expect(BuzzSequence.fromJson(s.toJson()), s);
      expect(() => _held([0, 2999], [3000, 80]), throwsArgumentError);
      expect(() => _held([0, 5001], [3000, 80]), throwsArgumentError);
    },
  );

  test('prefs and per-app relay JSON retain press durations', () {
    final s = _held([0, 900], [750, 80]);
    final prefs = const NotificationPrefs().withAlertRule({
      ...const NotificationPrefs().alertRule('water').toJson(),
      'buzzSequence': s.toJson(),
    });
    final back = NotificationPrefs.fromJson(
      jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>,
    );
    expect(back.buzzSequenceFor('water'), s);
    final cfg = const ChannelConfig(enabled: true).copyWith(
      buzzSequence: s,
      appSequences: {
        'com.example': _held([0], [80]),
      },
    );
    final json = jsonDecode(jsonEncode(cfg.toJson())) as Map<String, Object?>;
    final restored = ChannelConfig.fromJson(json, const ChannelConfig());
    expect(restored.effectiveSequence, s);
    expect(restored.sequenceForApp('com.example'), _held([0], [80]));
  });

  test('four separate rapid presses survive with their own durations', () {
    fakeAsync((async) {
      var starts = 0;
      final r = BuzzRecorder(onStart: () => starts++);
      for (var i = 0; i < 4; i++) {
        (r as dynamic).pressStart();
        async.elapse(const Duration(milliseconds: 20));
        (r as dynamic).pressEnd();
        if (i < 3) async.elapse(const Duration(milliseconds: 60));
      }
      async.elapse(const Duration(seconds: 2));
      expect(r.result!.offsetsMs, [0, 80, 160, 240]);
      expect((r.result as dynamic).durationsMs, [20, 20, 20, 20]);
      expect(starts, 1);
      r.dispose();
    });
  });

  test('a held press waits for release before starting the idle timeout', () {
    fakeAsync((async) {
      final r = BuzzRecorder();
      (r as dynamic).pressStart();
      async.elapse(const Duration(seconds: 3));
      expect(r.result, isNull);
      (r as dynamic).pressEnd();
      async.elapse(const Duration(milliseconds: 1999));
      expect(r.result, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect((r.result as dynamic).durationsMs, [3000]);
      r.dispose();
    });
  });

  test('cancelled press leaves no phantom entry', () {
    fakeAsync((async) {
      final r = BuzzRecorder();
      (r as dynamic).pressStart();
      async.elapse(const Duration(milliseconds: 50));
      (r as dynamic).pressCancel();
      async.elapse(const Duration(seconds: 3));
      expect(r.result, isNull);
      (r as dynamic).pressStart();
      async.elapse(const Duration(milliseconds: 80));
      (r as dynamic).pressEnd();
      async.elapse(const Duration(seconds: 2));
      expect(r.result!.offsetsMs, [0]);
      expect((r.result as dynamic).durationsMs, [80]);
      r.dispose();
    });
  });

  test(
    'slow confirmed writes preserve release gaps without catch-up bursts',
    () {
      fakeAsync((async) {
        final at = <int>[];
        final durations = <int>[];
        bool? result;
        final future =
            Function.apply(
                  playBuzzSequence,
                  [
                    _held([0, 900, 1200], [750, 80, 80]),
                  ],
                  {
                    #buzz: () async =>
                        throw StateError('duration transport expected'),
                    #buzzForDuration: (int holdMs) async {
                      at.add(async.elapsed.inMilliseconds);
                      durations.add(holdMs);
                      await Future<void>.delayed(
                        const Duration(milliseconds: 1000),
                      );
                      return true;
                    },
                    #isConnected: () => true,
                  },
                )
                as Future<bool>;
        future.then((ok) => result = ok);
        async.elapse(const Duration(seconds: 5));
        expect(durations, [750, 80, 80]);
        expect(at, [0, 1150, 2370]);
        expect(result, isTrue);
      });
    },
  );

  test('preview, notifications and relay forward duration-aware playback', () {
    final app = File('lib/state/app_state.dart').readAsStringSync();
    for (final signature in [
      'Future<bool> previewBuzzSequence(',
      'Future<AlertDeliveryOutcome> _dispatchBandAlert(',
    ]) {
      // Both reach the one delivery helper (now HapticsService.deliver).
      expect(
        codeOnly(bodyOf(app, signature)),
        contains('haptics.deliver('),
      );
    }
    // That the service forwards each tap's hold to the band: the per-tap
    // delivery tests in test/haptics_service_test.dart (holds [500,
    // 500] on gen4, buzzForDuration through the port).
    final relay = codeOnly(
      File('lib/notify/notification_relay.dart').readAsStringSync(),
    );
    expect(relay, contains('buzzForDuration:'));
    // The app hands the service's duration transport to the player (the ECG
    // failure buzz, which used to carry `holdMs: 600`, is now a cue).
    expect(codeOnly(app), contains('buzzForDuration: haptics.buzzForDuration'));
  });

  testWidgets('sheet ignores another pointer and discards a cancelled press', (
    t,
  ) async {
    final played = <BuzzSequence>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: BuzzPatternSheet(
            bandConnected: true,
            onPlay: (s) async {
              played.add(s);
              return true;
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final target = t.getCenter(find.text('Tap your pattern'));
    final first = await t.startGesture(target, pointer: 1);
    await t.pump(const Duration(milliseconds: 20));
    final other = await t.startGesture(target, pointer: 2);
    await t.pump(const Duration(milliseconds: 20));
    await other.up();
    await first.cancel();
    await t.pump(const Duration(milliseconds: 2100));
    expect(played, isEmpty);
    final next = await t.startGesture(target, pointer: 3);
    await t.pump(const Duration(milliseconds: 80));
    await next.up();
    await t.pump(const Duration(milliseconds: 2100));
    await t.pumpAndSettle();
    expect(played, hasLength(1));
    expect(played.single.offsetsMs, [0]);
    expect((played.single as dynamic).durationsMs, [80]);
  });

  testWidgets('sheet keeps a zero-duration accessibility tap action', (
    t,
  ) async {
    final handle = t.ensureSemantics();
    final played = <BuzzSequence>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: BuzzPatternSheet(
            bandConnected: true,
            onPlay: (s) async {
              played.add(s);
              return true;
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final node = t.getSemantics(find.bySemanticsLabel('Tap your pattern'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await t.pump(const Duration(milliseconds: 2100));
    await t.pumpAndSettle();
    expect(played, [
      BuzzSequence([0]),
    ]);
    handle.dispose();
  });

  test(
    'cancelling a held press after the idle deadline finishes the completed take',
    () {
      fakeAsync((async) {
        final done = <BuzzSequence>[];
        final r = BuzzRecorder(onDone: done.add);
        r.pressStart();
        async.elapse(const Duration(milliseconds: 20));
        r.pressEnd();
        async.elapse(const Duration(milliseconds: 1800));
        r.pressStart();
        async.elapse(const Duration(milliseconds: 300));
        expect(r.result, isNull, reason: 'an active hold pauses finalization');
        r.pressCancel();
        async.flushMicrotasks();
        expect(
          r.result,
          isNotNull,
          reason: 'the previous release was more than two seconds ago',
        );
        expect(r.result!.offsetsMs, [0]);
        expect(r.result!.durationsMs, [20]);
        expect(done, [r.result]);
        r.pressStart();
        async.elapse(const Duration(milliseconds: 80));
        r.pressEnd();
        expect(
          r.result!.offsetsMs,
          [0],
          reason: 'a finished take cannot append an invalid late gap',
        );
        r.dispose();
      });
    },
  );

  test(
    'cancelling before the idle deadline resumes only the remaining idle time',
    () {
      fakeAsync((async) {
        final r = BuzzRecorder();
        r.pressStart();
        async.elapse(const Duration(milliseconds: 20));
        r.pressEnd();
        async.elapse(const Duration(milliseconds: 1800));
        r.pressStart();
        async.elapse(const Duration(milliseconds: 100));
        r.pressCancel();
        async.elapse(const Duration(milliseconds: 99));
        expect(r.result, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(
          r.result,
          isNotNull,
          reason: 'cancellation does not restart the two-second idle window',
        );
        expect(r.result!.offsetsMs, [0]);
        expect(r.result!.durationsMs, [20]);
        r.dispose();
      });
    },
  );

  for (final longPress in [false, true]) {
    testWidgets(
      longPress
          ? 'sheet captures a 750 ms held press'
          : 'sheet records four presses 80 ms apart',
      (t) async {
        final played = <BuzzSequence>[];
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: BuzzPatternSheet(
                bandConnected: true,
                onPlay: (s) async {
                  played.add(s);
                  return true;
                },
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final target = t.getCenter(find.text('Tap your pattern'));
        for (var i = 0; i < (longPress ? 1 : 4); i++) {
          final gesture = await t.startGesture(target);
          await t.pump(Duration(milliseconds: longPress ? 750 : 20));
          await gesture.up();
          if (!longPress && i < 3) {
            await t.pump(const Duration(milliseconds: 60));
          }
        }
        await t.pump(const Duration(milliseconds: 2100));
        await t.pumpAndSettle();
        expect(played, hasLength(1));
        expect(played.single.offsetsMs, longPress ? [0] : [0, 80, 160, 240]);
        expect(
          (played.single as dynamic).durationsMs,
          longPress ? [750] : [20, 20, 20, 20],
        );
      },
    );
  }
}
