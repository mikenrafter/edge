// Gesture area: the ECG start path of a gesture
// (AppState._beginEcgForTap), through AppState with an ECG controller that
// records how it is asked to begin and a transport that logs PREPARE / START /
// CLEANUP into the same ordered trace as the band's haptic writes.
//
// Pinned: begin() is called with persist: false (a gesture never leaves an ECG
// reading behind, invariant 14) and PREPARE always carries the raw-save member
// (the ECG method has one path, the Fast mode is retired); the start cue is the first
// thing the band gets, PREPARE and START then run back to back with no haptic
// write between them; a capture the gesture did not start is left alone; an
// abandoned gesture buzzes the failure cue and keeps one failure record.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_ecg_start.db';

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
  late SpyEcg spy;
  late GestureRig rig;

  Future<void> start({bool wrist = true}) async {
    order = <String>[];
    channel = ActionChannel(order: order);
    addTearDown(channel.dispose);
    spy = SpyEcg(order, remembersWrist: wrist);
    rig = GestureRig(ecg: spy, order: order);
    addTearDown(rig.dispose);
    // Last in, first out: a stream still up ends here (the poll sees the drop
    // and abandons), before the app is disposed.
    addTearDown(() async {
      if (spy.isCapturing) {
        await spy.cancel();
        await settleMs(500);
      }
    });
    await rig.measureCues();
    // 2 and 3 mapped: a counted gesture, so the ECG route is taken.
    await mapActions(rig.app, [2, 3]);
  }

  Future<void> streamUp() => until(() => order.contains('ecg:start'));

  test('begin(persist: false), PREPARE with the raw-save member', () async {
    await start();
    rig.doubleTap();
    await streamUp();
    expect(spy.begins, [false]);
    expect(spy.prepares, [
      ['selectWrist', 'filteredOn', 'rawSaveOn']
    ]);
  });

  test('the start cue is written before PREPARE; PREPARE and START run back '
      'to back with no haptic write between them', () async {
    await start();
    rig.doubleTap();
    await streamUp();
    expect(order.first, 'cue:start');
    final prepare = order.indexOf('ecg:prepare');
    expect(prepare, greaterThan(0));
    expect(order.indexOf('ecg:start'), prepare + 1);
    expect(labText(rig), contains('ECG start: wrist looked up'),
        reason: 'the start trace goes to the Device lab log');
  });

  test('the stream is asked for through the controller the app owns: no '
      'second ECG owner is built', () async {
    await start();
    expect(identical(rig.app.ecg, spy), isTrue);
    rig.doubleTap();
    await streamUp();
    expect(identical(rig.app.ecg, spy), isTrue);
    expect(spy.isCapturing, isTrue);
  });

  test('the stream drops: failure cue, one ECG failure record, the stream is '
      'stopped, the double-tap fallback runs the 2-tap action', () async {
    await start();
    rig.doubleTap();
    await streamUp();
    await spy.cancel();
    await until(() => rig.cues.contains('failed'));
    await until(() => channel.performed.isNotEmpty);
    await settleMs(300);
    expect(rig.cues, ['start', 'failed']);
    expect(channel.performed, ['media_play_pause']);
    final f = rig.app.gestureFailures.all.single;
    expect(f.kind, GestureFailureKind.ecg);
    expect(f.reason, 'link_lost');
    expect(spy.isCapturing, isFalse);
    expect(labText(rig), contains('ECG failed (link_lost)'));
  });

  test('a capture the gesture did not start is left alone: no begin, the '
      'gesture fails to start and falls back', () async {
    await start();
    await spy.begin(EcgWrist.left); // the ECG screen's own reading
    expect(spy.isCapturing, isTrue);
    rig.doubleTap();
    await until(() => rig.cues.contains('failed'));
    await until(() => channel.performed.isNotEmpty);
    await settleMs(200);
    expect(spy.begins, [true], reason: 'only the user\'s own begin');
    expect(spy.isCapturing, isTrue, reason: 'never cancelled by the gesture');
    expect(order, isNot(contains('ecg:cleanup')));
    expect(rig.app.gestureFailures.all.single.reason, 'start_failed');
    expect(channel.performed, ['media_play_pause']);
  });

  test('no wrist remembered: nothing is begun, start cue then failure cue',
      () async {
    await start(wrist: false);
    rig.doubleTap();
    await until(() => rig.cues.contains('failed'));
    await settleMs(200);
    expect(spy.begins, isEmpty);
    expect(rig.cues, ['start', 'failed']);
    expect(order, isNot(contains('ecg:prepare')));
    expect(labText(rig), contains('No wrist remembered'));
  });
}
