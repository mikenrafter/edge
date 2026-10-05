// 8AJ seam 3 characterization: the gesture-failures store and the record
// AppState keeps when a gesture fails to activate (8AK D): what is persisted,
// what Home shows (the newest undismissed one), dismiss, de-duplication per
// gesture, and that the store object is one for the app's lifetime. Passes
// before and after the GestureController move.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';

import 'support/app_state_gesture_harness.dart';

List<dynamic> _stored() =>
    jsonDecode(Prefs.getString(Prefs.gestureFailures, '[]')) as List<dynamic>;

const _db = 'split8aj_seam3_failures.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
  });
  tearDown(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  late ActionChannel channel;
  late List<String> order;
  Future<GestureRig> newRig({bool mg = false}) async {
    order = <String>[];
    channel = ActionChannel(order: order, ok: false);
    addTearDown(channel.dispose);
    final rig = GestureRig(mg: mg, order: order);
    addTearDown(rig.dispose);
    await rig.measureCues();
    await rig.app.gestureSettings
        .setDoubleTapActions({DeviceAction.mediaPlayPause});
    return rig;
  }

  group('record', () {
    test('a failed double-tap action is recorded and persisted: kind, reason, '
        'the tap\'s identity, the lab log', () async {
      final rig = await newRig();
      rig.doubleTap();
      await until(() => rig.app.gestureFailures.all.isNotEmpty);
      await settleMs(200);
      final f = rig.app.gestureFailures.all.single;
      expect(f.kind, GestureFailureKind.doubleTap);
      expect(f.reason, startsWith('media_play_pause:'));
      expect(f.gestureId, matches(RegExp(r'^:14:\d+:\d+$')),
          reason: 'StrapEvent.identity of a plausible tap');
      expect(f.dismissed, isFalse);
      expect(f.log, contains('Gesture failed (media_play_pause:'));
      expect(f.log, startsWith('OpenStrap Device lab log'),
          reason: 'the Device lab log as it stood (labText)');
      final saved = _stored().single as Map;
      expect(saved['id'], f.gestureId);
      expect(saved['kind'], 'doubleTap');
      expect(saved['dismissed'], false);
    });

    test('a new app (a restart) loads what was persisted, on first use',
        () async {
      final first = await newRig();
      first.doubleTap();
      await until(() => first.app.gestureFailures.all.isNotEmpty);
      await settleMs(200);
      final id = first.app.gestureFailures.all.single.gestureId;
      await first.dispose();

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.gestureFailures.all.map((f) => f.gestureId), [id]);
      expect(app.gestureFailures.newestUndismissed?.gestureId, id);
    });

    test('the same failing tap delivered twice: the action is retried (its '
        'claim was given back) but only one record is kept', () async {
      final rig = await newRig();
      rig.doubleTap();
      await until(() => rig.app.gestureFailures.all.isNotEmpty);
      await settleMs(200);
      rig.doubleTap(resend: true);
      await until(() => channel.performed.length == 2);
      await settleMs(300);
      expect(channel.performed, ['media_play_pause', 'media_play_pause']);
      expect(rig.app.gestureFailures.all, hasLength(1));
      expect(_stored(), hasLength(1));
    });

    test('an ECG route that could not start is recorded as an ECG failure '
        '(start_failed); the fallback action failing too adds no second record '
        'for the same gesture', () async {
      final rig = await newRig(mg: true);
      await mapActions(rig.app, [2, 3]);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await until(() => rig.cues.contains('failed'));
      await settleMs(300);
      expect(channel.performed, ['media_play_pause']);
      final f = rig.app.gestureFailures.all.single;
      expect(f.kind, GestureFailureKind.ecg);
      expect(f.reason, 'start_failed');
    });

    test('a counted ECG gesture whose mapped action fails is an ECG failure '
        'naming the action', () async {
      final rig = await newRig(mg: true);
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      await mapActions(rig.app, [2, 3]);
      rig.doubleTap();
      await until(() => order.contains('band:generation'));
      await playEcgCount(rig, 3);
      await until(() => rig.app.gestureFailures.all.isNotEmpty,
          within: const Duration(seconds: 8));
      await settleMs(300);
      expect(channel.performed, ['media_next']);
      final f = rig.app.gestureFailures.all.single;
      expect(f.kind, GestureFailureKind.ecg);
      expect(f.reason, startsWith('media_next:'));
    });
  });

  group('exposure and dismiss', () {
    test('newest first; Home sees the newest undismissed; dismissing it '
        'dismisses the older ones too and persists that', () async {
      final rig = await newRig();
      rig.doubleTap();
      await until(() => rig.app.gestureFailures.all.length == 1);
      await settleMs(1100); // a distinct strap second for the next tap
      rig.doubleTap();
      await until(() => rig.app.gestureFailures.all.length == 2);
      await settleMs(200);
      final store = rig.app.gestureFailures;
      final newest = store.all.first, older = store.all.last;
      expect(newest.at.isAfter(older.at) || newest.at == older.at, isTrue);
      expect(store.newestUndismissed?.gestureId, newest.gestureId);

      await store.dismiss(newest.gestureId);
      expect(store.newestUndismissed, isNull,
          reason: 'a dismissed card supersedes the failures before it');
      expect(store.all.every((f) => f.dismissed), isTrue);
      expect(store.all, hasLength(2), reason: 'still listed in Settings');
      expect(_stored().every((e) => (e as Map)['dismissed'] == true), isTrue);
    });

    test('a failure after a dismissal is the new newest undismissed', () async {
      final rig = await newRig();
      rig.doubleTap();
      await until(() => rig.app.gestureFailures.all.length == 1);
      await settleMs(200);
      await rig.app.gestureFailures
          .dismiss(rig.app.gestureFailures.all.single.gestureId);
      expect(rig.app.gestureFailures.newestUndismissed, isNull);
      await settleMs(1100);
      rig.doubleTap();
      await until(() => rig.app.gestureFailures.all.length == 2);
      final fresh = rig.app.gestureFailures.newestUndismissed;
      expect(fresh, isNotNull);
      expect(fresh!.gestureId, rig.app.gestureFailures.all.first.gestureId);
    });
  });

  group('the store object', () {
    test('one store for the lifetime of the app (first use, later reads, '
        'a failure, dispose)', () async {
      final rig = await newRig();
      final store = rig.app.gestureFailures;
      expect(identical(rig.app.gestureFailures, store), isTrue);
      rig.doubleTap();
      await until(() => store.all.isNotEmpty);
      expect(identical(rig.app.gestureFailures, store), isTrue);
      await rig.dispose();
      expect(identical(rig.app.gestureFailures, store), isTrue);
    });

    test('two apps never share a store', () async {
      final a = AppState.forTesting();
      final b = AppState.forTesting();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      expect(identical(a.gestureFailures, b.gestureFailures), isFalse);
    });

    test('it notifies its own listeners once per new record and once per '
        'dismiss, and not for a duplicate', () async {
      final rig = await newRig();
      var ticks = 0;
      void on() => ticks++;
      rig.app.gestureFailures.addListener(on);
      addTearDown(() => rig.app.gestureFailures.removeListener(on));
      rig.doubleTap();
      await until(() => ticks > 0);
      await settleMs(200);
      expect(ticks, 1);
      rig.doubleTap(resend: true); // retried, the same gesture id
      await until(() => channel.performed.length == 2);
      await settleMs(300);
      expect(ticks, 1, reason: 'the duplicate record changes nothing');
      await rig.app.gestureFailures
          .dismiss(rig.app.gestureFailures.all.single.gestureId);
      expect(ticks, 2);
    });
  });
}
