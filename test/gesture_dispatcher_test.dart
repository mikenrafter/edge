// GestureDispatcher.handle(StrapEvent) — the production event dispatcher, driven
// headlessly with delayed, duplicate, fractional-time and out-of-order events.
//
// No real clock anywhere: every decision uses the event's own `receivedAt`.
// No sleeps: only `Future.delayed(Duration.zero)` to turn the microtask queue.
//
// The persistent "handle each occurrence once, ever" claim is injected as an
// in-memory set that OUTLIVES the dispatcher instances built from it — that is
// what a restart looks like. One group at the bottom uses the real default
// (LocalDb.claimNotifFired over sqflite_ffi) to pin the production wiring and
// the claim-key format.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Fixed instants, independent of today and of the machine zone.
final DateTime _t0 = DateTime.utc(2026, 3, 14, 12, 0, 0);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap({
  int tsEpoch = -1,
  int subsec = 0,
  Duration receivedAfter = const Duration(seconds: 1),
  DateTime? receivedAt,
  String device = 'dev-a',
  int id = 14,
}) {
  final ts = tsEpoch == -1 ? _t0Sec : tsEpoch;
  return StrapEvent(
    eventId: id,
    tsEpoch: ts,
    tsSubsec: subsec,
    receivedAt: receivedAt ??
        DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)
            .add(receivedAfter),
    hex: '',
    deviceId: device,
  );
}

/// A tap that reached the phone two hours after it happened.
StrapEvent _delayed({int subsec = 0, int tsEpoch = -1, String device = 'dev-a'}) =>
    _tap(
        tsEpoch: tsEpoch,
        subsec: subsec,
        receivedAfter: const Duration(hours: 2),
        device: device);

class _Rig {
  _Rig(this.settings, this.claimed);
  final GestureSettings settings;
  final Set<String> claimed; // the "persisted" claims; shared across restarts
  final List<String> calls = [];
  final List<String> logs = [];
  final List<StrapEvent> seen = [];

  Future<void> Function(StrapEvent)? markMoment;
  Future<void> Function(StrapEvent)? workout;
  Future<void> Function(StrapEvent)? tell;
  Future<bool> Function(String id)? native;
  Future<bool> Function(String key)? claimOverride;

  GestureDispatcher build({bool withMarkMoment = true,
      bool withWorkout = true, bool withTell = true}) {
    return GestureDispatcher(
      settings: settings,
      log: logs.add,
      onMarkMoment: withMarkMoment
          ? (markMoment ??
              (e) async {
                seen.add(e);
                calls.add('mark');
              })
          : null,
      onWorkoutToggle: withWorkout
          ? (workout ??
              (e) async {
                seen.add(e);
                calls.add('workout');
              })
          : null,
      // The third in-app action is Tell the time (Log water is retired); its
      // handler ignores the encoded elements.
      onTellTime: withTell
          ? (e, _) => (tell ??
              (e) async {
                seen.add(e);
                calls.add('tell');
              })(e)
          : null,
      performNative: native ??
          (id) async {
            calls.add('native:$id');
            return true;
          },
      claim: claimOverride ??
          (key) async {
            await Future<void>.delayed(Duration.zero);
            return claimed.add(key);
          },
      release: (key) async => claimed.remove(key),
    );
  }
}

Future<_Rig> _rig(Set<DeviceAction> actions, {Set<String>? claimed}) async {
  SharedPreferences.setMockInitialValues({});
  final s = GestureSettings();
  await s.setDoubleTapActions(actions);
  return _Rig(s, claimed ?? <String>{});
}

List<GestureStatus> _statuses(List<GestureOutcome> o) =>
    [for (final x in o) x.status];

GestureOutcome _of(List<GestureOutcome> o, DeviceAction a) =>
    o.singleWhere((x) => x.action == a);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('which events, which actions, what order', () {
    test('only double-tap (14) is a gesture; everything else is ignored',
        () async {
      final r = await _rig({DeviceAction.tellTime});
      final out = await r.build().handle(_tap(id: 7)); // charging on
      expect(out, isEmpty);
      expect(r.calls, isEmpty);
      expect(r.claimed, isEmpty, reason: 'not a gesture, nothing to claim');
    });

    test('nothing selected is an empty outcome list and no work', () async {
      final r = await _rig({});
      expect(await r.build().handle(_tap()), isEmpty);
      expect(r.calls, isEmpty);
    });

    test('a live tap runs every selected action, in enum order', () async {
      // Selected in the "wrong" order on purpose.
      final r = await _rig({
        DeviceAction.tellTime,
        DeviceAction.torch,
        DeviceAction.markMoment,
        DeviceAction.workoutToggle,
        DeviceAction.mediaPlayPause,
      });
      final out = await r.build().handle(_tap());
      expect(r.calls, [
        'native:media_play_pause',
        'native:torch',
        'mark',
        'workout',
        'tell',
      ]);
      expect([for (final o in out) o.action], [
        DeviceAction.mediaPlayPause,
        DeviceAction.torch,
        DeviceAction.markMoment,
        DeviceAction.workoutToggle,
        DeviceAction.tellTime,
      ]);
      expect(_statuses(out), everyElement(GestureStatus.ran));
    });

    test('in-app handlers receive the event itself (strap time, not the clock)',
        () async {
      final r = await _rig({DeviceAction.markMoment});
      final e = _tap(subsec: 16384);
      await r.build().handle(e);
      expect(identical(r.seen.single, e), isTrue);
      expect(r.seen.single.strapTime.millisecond, 500);
    });

    test('handlers are awaited in order: the next action waits for the last one',
        () async {
      final r = await _rig({DeviceAction.markMoment, DeviceAction.tellTime});
      final gate = Completer<void>();
      r.markMoment = (e) async {
        r.calls.add('mark:start');
        await gate.future;
        r.calls.add('mark:end');
      };
      final done = r.build().handle(_tap());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(r.calls, ['mark:start'], reason: 'tell must not start yet');
      gate.complete();
      await done;
      expect(r.calls, ['mark:start', 'mark:end', 'tell']);
    });
  });

  group('one action failing never stops the others', () {
    test('a synchronous throw', () async {
      final r = await _rig({
        DeviceAction.torch,
        DeviceAction.markMoment,
        DeviceAction.tellTime,
      });
      r.markMoment = (e) {
        throw StateError('journal exploded');
      };
      final out = await r.build().handle(_tap());
      expect(r.calls, ['native:torch', 'tell']);
      expect(_of(out, DeviceAction.markMoment).status, GestureStatus.failed);
      expect(_of(out, DeviceAction.markMoment).error.toString(),
          contains('journal exploded'));
      expect(_of(out, DeviceAction.torch).status, GestureStatus.ran);
      expect(_of(out, DeviceAction.tellTime).status, GestureStatus.ran);
    });

    test('an asynchronous error', () async {
      final r = await _rig({
        DeviceAction.torch,
        DeviceAction.markMoment,
        DeviceAction.tellTime,
      });
      r.markMoment = (e) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('late failure');
      };
      final out = await r.build().handle(_tap());
      expect(r.calls, ['native:torch', 'tell']);
      expect(_of(out, DeviceAction.markMoment).status, GestureStatus.failed);
      expect(_of(out, DeviceAction.markMoment).error.toString(),
          contains('late failure'));
    });

    test('a native action that throws, and one that reports false', () async {
      final r = await _rig({
        DeviceAction.mediaPlayPause,
        DeviceAction.torch,
        DeviceAction.tellTime,
      });
      r.native = (id) async {
        r.calls.add('native:$id');
        if (id == 'media_play_pause') throw StateError('channel gone');
        return false; // torch: native says it could not
      };
      final out = await r.build().handle(_tap());
      expect(_of(out, DeviceAction.mediaPlayPause).status, GestureStatus.failed);
      expect(_of(out, DeviceAction.torch).status, GestureStatus.failed);
      expect(_of(out, DeviceAction.tellTime).status, GestureStatus.ran);
      expect(r.calls, contains('tell'));
    });

    test('an in-app action with no handler wired is a failure, not silence',
        () async {
      final r = await _rig({DeviceAction.workoutToggle, DeviceAction.tellTime});
      final out = await r.build(withWorkout: false).handle(_tap());
      expect(_of(out, DeviceAction.workoutToggle).status, GestureStatus.failed);
      expect(_of(out, DeviceAction.tellTime).status, GestureStatus.ran);
    });

    test('every action failing still returns normally', () async {
      final r = await _rig({DeviceAction.markMoment, DeviceAction.tellTime});
      r.markMoment = (e) async => throw StateError('a');
      r.tell = (e) async => throw StateError('b');
      final out = await r.build().handle(_tap());
      expect(_statuses(out), [GestureStatus.failed, GestureStatus.failed]);
    });

    test('failures are logged by action id', () async {
      final r = await _rig({DeviceAction.markMoment});
      r.markMoment = (e) async => throw StateError('boom');
      await r.build().handle(_tap());
      expect(r.logs.where((l) => l.contains('mark_moment') && l.contains('boom')),
          isNotEmpty);
    });

    test('no failure ever escapes as an unhandled asynchronous error', () async {
      final r = await _rig({
        DeviceAction.markMoment,
        DeviceAction.workoutToggle,
        DeviceAction.tellTime,
        DeviceAction.torch,
      });
      r.markMoment = (e) {
        throw StateError('sync');
      };
      r.workout = (e) async => throw StateError('async');
      r.tell = (e) => Future<void>.error(StateError('future'));
      r.native = (id) async => throw StateError('native');
      final stray = <Object>[];
      await runZonedGuarded(() async {
        await r.build().handle(_tap());
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }, (e, _) => stray.add(e));
      expect(stray, isEmpty);
    });

    test('a failed action releases its claim so a retry can run it, and a '
        'sibling that succeeded keeps its own', () async {
      final r = await _rig({DeviceAction.markMoment, DeviceAction.tellTime});
      var attempts = 0;
      r.markMoment = (e) async {
        attempts++;
        if (attempts == 1) throw StateError('first try fails');
        r.calls.add('mark');
      };
      final e = _tap();
      final d = r.build();
      final first = await d.handle(e);
      expect(_of(first, DeviceAction.markMoment).status, GestureStatus.failed);
      expect(r.claimed, contains('gesture:${e.identity}:tell_time'));
      expect(r.claimed, isNot(contains('gesture:${e.identity}:mark_moment')));

      final retry = await d.handle(e);
      expect(_of(retry, DeviceAction.markMoment).status, GestureStatus.ran);
      expect(_of(retry, DeviceAction.tellTime).status,
          GestureStatus.skippedDuplicate);
      expect(r.calls.where((c) => c == 'tell'), hasLength(1));
    });

    test('a claim that cannot be decided is a failure for THAT action only; '
        'the handler is not run', () async {
      final r = await _rig({DeviceAction.markMoment, DeviceAction.tellTime});
      r.claimOverride = (key) async {
        if (key.endsWith(':mark_moment')) throw StateError('db unavailable');
        return r.claimed.add(key);
      };
      final out = await r.build().handle(_tap());
      expect(_of(out, DeviceAction.markMoment).status, GestureStatus.failed);
      expect(r.calls, ['tell']);
    });
  });

  group('duplicates: each occurrence is handled at most once, EVER', () {
    test('the claim key is gesture:<identity>:<action id>', () async {
      final r = await _rig({DeviceAction.tellTime, DeviceAction.torch});
      final e = _tap(subsec: 321);
      await r.build().handle(e);
      expect(r.claimed, {
        'gesture:${e.identity}:tell_time',
        'gesture:${e.identity}:torch',
      });
    });

    test('the same event twice: second is skippedDuplicate for every action',
        () async {
      final r = await _rig({DeviceAction.torch, DeviceAction.tellTime});
      final d = r.build();
      final e = _tap();
      await d.handle(e);
      final again = await d.handle(e);
      expect(_statuses(again), everyElement(GestureStatus.skippedDuplicate));
      expect(r.calls, ['native:torch', 'tell']);
    });

    test('a re-send after reconnect: replayable action is a duplicate, the '
        'others are stale — and nothing runs twice', () async {
      final r = await _rig({DeviceAction.markMoment, DeviceAction.tellTime});
      final d = r.build();
      await d.handle(_tap()); // the live delivery
      final resent = await d.handle(_tap(receivedAfter: const Duration(minutes: 4)));
      expect(_of(resent, DeviceAction.markMoment).status,
          GestureStatus.skippedDuplicate);
      expect(_of(resent, DeviceAction.tellTime).status,
          GestureStatus.skippedStale);
      expect(r.calls, ['mark', 'tell']);
    });

    test('across a restart: a fresh dispatcher on the same persisted claims '
        'still sees the duplicate', () async {
      final claims = <String>{};
      final first = await _rig({DeviceAction.tellTime, DeviceAction.torch},
          claimed: claims);
      await first.build().handle(_tap());

      final second = await _rig({DeviceAction.tellTime, DeviceAction.torch},
          claimed: claims);
      // Re-delivered inside the live window (reconnect within seconds).
      final out = await second.build().handle(_tap(receivedAfter: const Duration(seconds: 3)));
      expect(_statuses(out), everyElement(GestureStatus.skippedDuplicate));
      expect(second.calls, isEmpty);
    });

    test('two DIFFERENT taps in the same second (different subsec) both run',
        () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      final a = await d.handle(_tap(subsec: 100));
      final b = await d.handle(_tap(subsec: 16384));
      expect(_statuses(a), [GestureStatus.ran]);
      expect(_statuses(b), [GestureStatus.ran]);
      expect(r.calls, ['tell', 'tell']);
    });

    test('the same instant on two bands is two occurrences', () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      await d.handle(_tap(device: 'band-1'));
      final out = await d.handle(_tap(device: 'band-2'));
      expect(_statuses(out), [GestureStatus.ran]);
    });

    test('an action added later runs for a re-sent tap; the old one does not',
        () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      await d.handle(_tap());
      await r.settings
          .setDoubleTapActions({DeviceAction.tellTime, DeviceAction.torch});
      final out = await d.handle(_tap(receivedAfter: const Duration(seconds: 2)));
      expect(_of(out, DeviceAction.tellTime).status,
          GestureStatus.skippedDuplicate);
      expect(_of(out, DeviceAction.torch).status, GestureStatus.ran);
    });

    test('two overlapping deliveries of one tap: exactly one runs it', () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      final e = _tap();
      final both = await Future.wait([d.handle(e), d.handle(e)]);
      final all = [for (final o in both) ...o];
      expect(all.where((o) => o.status == GestureStatus.ran), hasLength(1));
      expect(all.where((o) => o.status == GestureStatus.skippedDuplicate),
          hasLength(1));
      expect(r.calls, ['tell']);
    });
  });

  group('out-of-order receipt', () {
    test('newer then older: both run, each under its own identity', () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      final newer = _tap(tsEpoch: _t0Sec + 5, receivedAfter: const Duration(milliseconds: 500));
      // The older tap reaches the phone after the newer one, still inside 6 s.
      final older = _tap(
          tsEpoch: _t0Sec + 1,
          receivedAt: newer.receivedAt.add(const Duration(milliseconds: 200)));
      expect(_statuses(await d.handle(newer)), [GestureStatus.ran]);
      expect(_statuses(await d.handle(older)), [GestureStatus.ran]);
      expect(r.seen.map((e) => e.tsEpoch), [_t0Sec + 5, _t0Sec + 1]);
    });

    test('arrival order does not change which occurrences run', () async {
      Future<Set<String>> run(List<StrapEvent> order) async {
        final r = await _rig({DeviceAction.markMoment});
        final d = r.build();
        for (final e in order) {
          await d.handle(e);
        }
        return {for (final e in r.seen) e.identity};
      }

      final a = _delayed(tsEpoch: _t0Sec, subsec: 1);
      final b = _delayed(tsEpoch: _t0Sec + 60, subsec: 2);
      final c = _delayed(tsEpoch: _t0Sec + 30, subsec: 3);
      final fwd = await run([a, b, c]);
      final rev = await run([c, b, a]);
      final mix = await run([b, a, c]);
      expect(fwd, {a.identity, b.identity, c.identity});
      expect(rev, fwd);
      expect(mix, fwd);
    });

    test('a delayed older tap after a live newer one still replays Mark moment',
        () async {
      final r = await _rig({DeviceAction.markMoment, DeviceAction.tellTime});
      final d = r.build();
      await d.handle(_tap(tsEpoch: _t0Sec + 3600));
      final out = await d.handle(_delayed());
      expect(_of(out, DeviceAction.markMoment).status, GestureStatus.ran);
      expect(_of(out, DeviceAction.tellTime).status, GestureStatus.skippedStale);
    });
  });

  group('recency: live vs delayed', () {
    test('6 s old is still live (inclusive); one microsecond more is stale',
        () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      final onTheLine = _tap(receivedAfter: const Duration(seconds: 6));
      expect(_statuses(await d.handle(onTheLine)), [GestureStatus.ran]);

      final pastIt = _tap(
          tsEpoch: _t0Sec + 100,
          receivedAfter: const Duration(seconds: 6, microseconds: 1));
      final out = await d.handle(pastIt);
      expect(_statuses(out), [GestureStatus.skippedStale]);
      expect(r.calls, ['tell']);
      expect(r.claimed, isNot(contains('gesture:${pastIt.identity}:tell_time')),
          reason: 'a stale skip must not use up the occurrence');
    });

    test('fractional seconds count: 0.5 s of subsec rescues a 6.5 s delivery',
        () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      const late = Duration(seconds: 6, milliseconds: 500);
      final withSubsec = await d.handle(_tap(subsec: 16384, receivedAfter: late));
      expect(_statuses(withSubsec), [GestureStatus.ran]);
      final without =
          await d.handle(_tap(tsEpoch: _t0Sec + 50, subsec: 0, receivedAfter: late));
      expect(_statuses(without), [GestureStatus.skippedStale]);
    });

    test('a tap from hours or days ago replays ONLY Mark moment', () async {
      for (final age in const [Duration(hours: 2), Duration(days: 3)]) {
        final r = await _rig({
          DeviceAction.markMoment,
          DeviceAction.workoutToggle,
          DeviceAction.tellTime,
          DeviceAction.torch,
          DeviceAction.ringPhone,
        });
        final out = await r.build().handle(_tap(receivedAfter: age));
        expect(_of(out, DeviceAction.markMoment).status, GestureStatus.ran,
            reason: '$age');
        for (final a in [
          DeviceAction.workoutToggle,
          DeviceAction.tellTime,
          DeviceAction.torch,
          DeviceAction.ringPhone,
        ]) {
          expect(_of(out, a).status, GestureStatus.skippedStale,
              reason: '$a @ $age');
        }
        expect(r.calls, ['mark'], reason: 'no native call, no tell, no workout');
      }
    });

    test('a native action is never replayed for an old tap', () async {
      final r = await _rig({DeviceAction.mediaPlayPause});
      final out = await r.build().handle(_delayed());
      expect(_statuses(out), [GestureStatus.skippedStale]);
      expect(r.calls, isEmpty);
    });

    test('turning replay off makes Mark moment stale too — and that skip does '
        'not use up the occurrence', () async {
      final r = await _rig({DeviceAction.markMoment});
      final d = r.build();
      await r.settings.setReplayHistorical(DeviceAction.markMoment, false);
      final e = _delayed();
      expect(_statuses(await d.handle(e)), [GestureStatus.skippedStale]);
      expect(r.calls, isEmpty);

      await r.settings.setReplayHistorical(DeviceAction.markMoment, true);
      expect(_statuses(await d.handle(e)), [GestureStatus.ran]);
      expect(r.calls, ['mark']);
    });

    test('a LIVE tap is not affected by the replay switch', () async {
      final r = await _rig({DeviceAction.markMoment});
      await r.settings.setReplayHistorical(DeviceAction.markMoment, false);
      expect(_statuses(await r.build().handle(_tap())), [GestureStatus.ran]);
    });
  });

  group('an implausible strap clock', () {
    test('unset RTC (epoch 0) is treated as live; the outcome says it used the '
        'receipt', () async {
      final r = await _rig({DeviceAction.tellTime, DeviceAction.markMoment});
      final out = await r.build().handle(_tap(tsEpoch: 0, receivedAt: _t0));
      expect(_statuses(out), everyElement(GestureStatus.ran));
      for (final o in out) {
        expect(o.timeSource, EventTimeSource.receipt, reason: '${o.action}');
      }
    });

    test('a strap clock hours in the future is the same', () async {
      final r = await _rig({DeviceAction.tellTime});
      final out = await r
          .build()
          .handle(_tap(tsEpoch: _t0Sec + 7200, receivedAt: _t0));
      expect(_statuses(out), [GestureStatus.ran]);
      expect(out.single.timeSource, EventTimeSource.receipt);
    });

    test('a plausible clock reports strap as the time source', () async {
      final r = await _rig({DeviceAction.tellTime});
      final out = await r.build().handle(_tap());
      expect(out.single.timeSource, EventTimeSource.strap);
    });

    test('an unset RTC must not lock the feature out: taps 10 s apart both run, '
        'and nothing is claimed persistently', () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      final one = await d.handle(_tap(tsEpoch: 0, receivedAt: _t0));
      final two = await d.handle(
          _tap(tsEpoch: 0, receivedAt: _t0.add(const Duration(seconds: 10))));
      expect(_statuses(one), [GestureStatus.ran]);
      expect(_statuses(two), [GestureStatus.ran]);
      expect(r.claimed, isEmpty,
          reason: 'with no usable clock there is no occurrence identity to persist');
    });

    test('...but one physical tap delivered twice within 2 s of RECEIPT time is '
        'still collapsed', () async {
      final r = await _rig({DeviceAction.tellTime});
      final d = r.build();
      await d.handle(_tap(tsEpoch: 0, receivedAt: _t0));
      final dup = await d.handle(
          _tap(tsEpoch: 0, receivedAt: _t0.add(const Duration(milliseconds: 1999))));
      expect(_statuses(dup), [GestureStatus.skippedDuplicate]);
      // Measured from the last ACCEPTED tap (a duplicate does not extend it),
      // and 2.000 s is not "within" 2 s.
      final next = await d.handle(
          _tap(tsEpoch: 0, receivedAt: _t0.add(const Duration(seconds: 2))));
      expect(_statuses(next), [GestureStatus.ran]);
      expect(r.calls, ['tell', 'tell']);
    });
  });

  group('outcomes', () {
    test('a failed outcome carries the error; a ran outcome carries none',
        () async {
      final r = await _rig({DeviceAction.markMoment, DeviceAction.tellTime});
      r.markMoment = (e) async => throw ArgumentError('bad day');
      final out = await r.build().handle(_tap());
      expect(_of(out, DeviceAction.markMoment).error, isA<ArgumentError>());
      expect(_of(out, DeviceAction.tellTime).error, isNull);
    });

    test('skipped actions are reported too, in enum order', () async {
      final r = await _rig({
        DeviceAction.markMoment,
        DeviceAction.tellTime,
        DeviceAction.torch,
      });
      final out = await r.build().handle(_delayed());
      expect([for (final o in out) o.action],
          [DeviceAction.torch, DeviceAction.markMoment, DeviceAction.tellTime]);
      expect(_statuses(out), [
        GestureStatus.skippedStale,
        GestureStatus.ran,
        GestureStatus.skippedStale,
      ]);
    });
  });

  group('production wiring: the default claim is LocalDb.claimNotifFired', () {
    const dbName = 'gestures_dispatcher_claims_test.db';

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = dbName;
      await databaseFactory
          .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      await databaseFactory
          .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), dbName));
    });

    GestureDispatcher fresh(GestureSettings s, List<String> calls) =>
        GestureDispatcher(
          settings: s,
          onTellTime: (e, _) async => calls.add('tell'),
          // `claim` / `release` deliberately NOT injected.
        );

    test('a tap handled by one dispatcher is a duplicate for the next one '
        '(an app restart)', () async {
      SharedPreferences.setMockInitialValues({});
      final s = GestureSettings();
      await s.setDoubleTapActions({DeviceAction.tellTime});
      final calls = <String>[];
      final e = _tap(device: 'db-dev-1', subsec: 7);

      expect(_statuses(await fresh(s, calls).handle(e)), [GestureStatus.ran]);
      expect(await LocalDb.notifFiredExists('gesture:${e.identity}:tell_time'),
          isTrue);

      final afterRestart = await fresh(s, calls).handle(
          _tap(device: 'db-dev-1', subsec: 7, receivedAfter: const Duration(seconds: 2)));
      expect(_statuses(afterRestart), [GestureStatus.skippedDuplicate]);
      expect(calls, ['tell']);
    });

    test('a failed action releases its row in the real store', () async {
      SharedPreferences.setMockInitialValues({});
      final s = GestureSettings();
      await s.setDoubleTapActions({DeviceAction.tellTime});
      final e = _tap(device: 'db-dev-2', subsec: 9);
      final d = GestureDispatcher(
        settings: s,
        onTellTime: (e, _) async => throw StateError('nope'),
      );
      expect(_statuses(await d.handle(e)), [GestureStatus.failed]);
      expect(await LocalDb.notifFiredExists('gesture:${e.identity}:tell_time'),
          isFalse);
    });
  });
}
