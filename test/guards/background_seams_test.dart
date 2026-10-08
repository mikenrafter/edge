// background_seams_test.dart — design 02, rev 6/7: the background entries get
// injectable seams so tests can drive the REAL handler on a CI host.
//
//   IosBgTask.install({isIOS})      — `init` with the platform check injectable.
//   HeadlessBoot.run({isAndroid})   — returns a Future<void> that completes when
//                                     its sync/derivation work completes (the
//                                     platform callback still `unawaited`s it).
//                                     `resetForTest()` clears its one-shot state.
//
// AndroidBootSignal gets the same `isAndroid` seam, so the whole boot wake
// (pending signal -> paired band -> band lease -> tracking service -> drain
// through HeadlessSyncGate) runs here with fakes for the platform edges.
//
// Step 1 only needs the seams to exist and behave as seams; the audit that
// derivation inside these entries is reached ONLY through a registered
// dispatcher (spy on the dispatcher registry, first heavy call) comes with the
// migration step that routes them (design 02 migration step 2+).
//

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/android_boot_signal.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/headless_boot.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/ios_bg_task.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

const _bgChannel = MethodChannel('openstrap/bg_task');

/// What the Dart side answers when the native side calls [method] on the bg
/// channel: null when NO handler is registered, otherwise the encoded reply.
Future<ByteData?> _callFromNative(String method) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  return messenger.handlePlatformMessage(
    _bgChannel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _bgChannel.setMethodCallHandler(null));
  tearDown(() => _bgChannel.setMethodCallHandler(null));

  group('IosBgTask.install', () {
    test('with isIOS true it registers the openstrap/bg_task handler', () async {
      await IosBgTask.install(isIOS: () => true);
      final reply = await _callFromNative('not_run');
      expect(reply, isNotNull, reason: 'a handler answered');
      expect(const StandardMethodCodec().decodeEnvelope(reply!), isNull,
          reason: 'only the `run` method does work; others return null');
    });

    test('with isIOS false it registers nothing', () async {
      await IosBgTask.install(isIOS: () => false);
      expect(await _callFromNative('not_run'), isNull);
    });

    test('init() on a non-iOS host still registers nothing', () async {
      await IosBgTask.init();
      expect(await _callFromNative('not_run'), isNull);
    });
  });

  group('HeadlessBoot.run', () {
    test('returns an awaitable Future<void>', () async {
      final Future<void> f = HeadlessBoot.run(isAndroid: () => false);
      await f;
    });

    test('off Android it does nothing and completes', () async {
      await HeadlessBoot.run(isAndroid: () => false);
    });

    test('on Android with no pending boot signal it completes without a wake',
        () async {
      HeadlessBoot.resetForTest();
      // AndroidBootSignal itself answers false off-device, so no band lease is
      // taken and nothing is started: the seam is safe to drive on a CI host.
      await HeadlessBoot.run(isAndroid: () => true);
    });

    test('resetForTest allows the one-shot to run again', () async {
      HeadlessBoot.resetForTest();
      await HeadlessBoot.run(isAndroid: () => true);
      HeadlessBoot.resetForTest();
      await HeadlessBoot.run(isAndroid: () => true);
    });
  });

  group('HeadlessBoot.run: the real wake path with fakes', () {
    var tracking = 0;
    var drains = 0;
    var gateBusyDuringDrain = false;

    setUp(() {
      HeadlessBoot.resetForTest();
      tracking = 0;
      drains = 0;
      gateBusyDuringDrain = false;
    });

    Future<void> wake({
      bool pending = true,
      PairedDevice? paired,
      bool awaitDrain = true,
      Future<void>? hold,
    }) =>
        HeadlessBoot.run(
          isAndroid: () => true,
          consumePendingBoot: () async => pending,
          loadPaired: () async => paired,
          startTracking: () async => tracking++,
          awaitDrain: awaitDrain,
          runner: (lease) async {
            drains++;
            gateBusyDuringDrain = HeadlessSyncGate.busy;
            await hold;
            BandOwnership.release(lease);
            return true;
          },
        );

    test('pending boot + paired band: starts tracking and drains through the gate',
        () async {
      await wake(paired: PairedDevice('AA:BB:CC', 'serial'));
      expect((tracking, drains), (1, 1));
      expect(gateBusyDuringDrain, isTrue,
          reason: 'the drain is serialised through HeadlessSyncGate');
      expect(BandOwnership.owner, isNull, reason: 'lease released');
    });

    test('no pending boot signal: nothing starts', () async {
      await wake(pending: false, paired: PairedDevice('AA:BB:CC', null));
      expect((tracking, drains), (0, 0));
    });

    test('no paired band: nothing starts', () async {
      await wake();
      expect((tracking, drains), (0, 0));
    });

    test('it runs once per process: a second call is a no-op until reset', () async {
      final band = PairedDevice('AA:BB:CC', null);
      await wake(paired: band);
      await wake(paired: band);
      expect(drains, 1);
      HeadlessBoot.resetForTest();
      await wake(paired: band);
      expect(drains, 2);
    });

    test('awaitDrain false (what main() uses) returns before the drain ends',
        () async {
      final hold = Completer<void>();
      await wake(
          paired: PairedDevice('AA:BB:CC', null),
          awaitDrain: false,
          hold: hold.future);
      expect((tracking, drains), (1, 1), reason: 'drain started');
      expect(HeadlessSyncGate.busy, isTrue, reason: 'and is still running');
      hold.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(HeadlessSyncGate.busy, isFalse);
    });

    test('a foreground owner holds the band: the wake is skipped', () async {
      final fg = await BandOwnership.acquireForeground();
      addTearDown(() => BandOwnership.release(fg));
      await wake(paired: PairedDevice('AA:BB:CC', null));
      expect(drains, 0);
    });
  });

  group('AndroidBootSignal.isAndroid seam', () {
    const edge = MethodChannel('openstrap/edge_tracking');
    var calls = 0;

    setUp(() {
      calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(edge, (call) async {
        calls++;
        return call.method == 'consumeHeadlessBootPending' ? true : null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(edge, null));

    test('isAndroid true asks the native side', () async {
      expect(
          await AndroidBootSignal.consumePendingHeadlessBoot(isAndroid: () => true),
          isTrue);
      expect(calls, 1);
    });

    test('isAndroid false never reaches the platform channel', () async {
      expect(
          await AndroidBootSignal.consumePendingHeadlessBoot(isAndroid: () => false),
          isFalse);
      expect(calls, 0);
    });

    test('HeadlessBoot.run asks the native signal with ITS isAndroid', () async {
      HeadlessBoot.resetForTest();
      await HeadlessBoot.run(isAndroid: () => true, loadPaired: () async => null);
      expect(calls, 1);
    });
  });
}
