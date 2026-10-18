// Live-stream area: what AppState.dispose leaves behind from the
// live-stream machinery (timers, listeners, in-flight owner changes), the
// identity of the liveStreams buffer across the app's lifetime, and what the
// live entry points do after dispose.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/polar_pmd_link.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_derive_harness.dart' show TimerSpy, settleMs;
import 'support/app_state_live_harness.dart';

// ValueListenable has no public hasListeners; the real notifiers are
// ChangeNotifiers.
bool _hasListeners(ValueListenable<Object?> n) =>
    // ignore: invalid_use_of_protected_member
    (n as ChangeNotifier).hasListeners;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('liveStreams identity', () {
    test('one buffer for the whole lifetime: construction, owner changes, '
        'frames and dispose', () async {
      final rig = G6Rig();
      final buf = rig.app.liveStreams;
      expect(identical(rig.app.liveStreams, buf), isTrue);
      await rig.app.startLiveFeed(kBandId);
      rig.app.retainLiveHrView();
      rig.feed(r21LiveInner());
      expect(identical(rig.app.liveStreams, buf), isTrue);
      await rig.app.stopLiveFeed(kBandId);
      rig.app.releaseLiveHrView();
      expect(identical(rig.app.liveStreams, buf), isTrue);
      await rig.dispose();
      expect(identical(rig.app.liveStreams, buf), isTrue);
    });

    test('the buffer is a LiveStreamBuffer with the default 30 s window, '
        'readable after dispose (dispose does not clear it)', () {
      final app = AppState.forTesting();
      final LiveStreamBuffer buf = app.liveStreams;
      expect(buf.window, const Duration(seconds: 30));
      app.debugAppendLiveHr(kBandId, 60, 1000);
      app.dispose();
      expect(buf.retained(kBandId, 'hr').map((s) => s.value), [60.0]);
    });

    test('two apps never share a buffer', () {
      final a = AppState.forTesting();
      final b = AppState.forTesting();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      expect(identical(a.liveStreams, b.liveStreams), isFalse);
    });
  });

  group('timers', () {
    test('owner changes and a flood of frames leave no timer behind after '
        'dispose', () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final rig = G6Rig();
        await rig.app.startLiveFeed(kBandId);
        rig.app.retainLiveHrView();
        rig.app.setMovementSamplingWindow(true);
        await rig.settle();
        for (var i = 0; i < 3; i++) {
          rig.feed(hr28Inner(hr: 60 + i, rr: [800], ts: nowSec() + i));
          rig.feed(r21LiveInner());
        }
        await rig.app.stopLiveFeed(kBandId);
        rig.app.releaseLiveHrView();
        rig.app.setMovementSamplingWindow(false);
        await rig.settle();
        await rig.dispose();
        await settleMs(250);
        expect(spy.live, isEmpty,
            reason: 'live: ${spy.live.length} of ${spy.created} created');
      });
    });

    test('the live feed itself arms no timer of its own (before the engine '
        'reconcile settles, with the feed left on at dispose)', () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final app = AppState.forTesting();
        final before = spy.created;
        await app.startLiveFeed(kBandId);
        app.retainLiveHrView();
        app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner()), null);
        expect(spy.created, before,
            reason: 'start / retain / a live frame create no Timer');
        app.dispose();
        await settleMs(100);
        expect(spy.live, isEmpty);
      });
    });
  });

  group('listeners', () {
    test('the sensor notifiers have no AppState listener after dispose '
        '(the live-HR append is fed from them)', () {
            final hrsBefore = _hasListeners(HrsLink.instance.reading);
            final pmdBefore = _hasListeners(PolarPmdLink.instance.reading);
      final app = AppState.forTesting();
            expect(_hasListeners(HrsLink.instance.reading), isTrue);
            expect(_hasListeners(PolarPmdLink.instance.reading), isTrue);
      app.dispose();
            expect(_hasListeners(HrsLink.instance.reading), hrsBefore);
            expect(_hasListeners(PolarPmdLink.instance.reading), pmdBefore);
    });

    test('owner changes and frames add no listener to AppState itself; a '
        'screen\'s add / remove balances', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      var heard = 0;
      void on() => heard++;
      rig.app.addListener(on);
      await rig.app.startLiveFeed(kBandId);
      rig.app.retainLiveHrView();
      rig.feed(r21LiveInner());
      rig.app.removeListener(on);
      final seen = heard;
      await rig.app.stopLiveFeed(kBandId);
      rig.app.releaseLiveHrView();
      expect(heard, seen, reason: 'a removed listener hears nothing more');
    });
  });

  group('dispose', () {
    test('a stop that is still awaiting the engine when AppState is disposed '
        'completes, and the owner is already clear', () async {
      final rig = G6Rig();
      await rig.app.startLiveFeed(kBandId);
      await rig.settle();
      final pending = rig.app.stopLiveFeed(kBandId);
      rig.app.dispose();
      await expectLater(pending, completes);
      expect(rig.app.isLiveFeedOn(kBandId), isFalse);
      BleEngine.resetBandClaimForTest();
    });

    test('the live entry points do not throw after dispose, and nothing '
        'notifies a disposed notifier', () async {
      final rig = G6Rig();
      await rig.app.startLiveFeed(kBandId);
      rig.app.retainLiveHrView();
      await rig.settle();
      rig.app.dispose();
      await expectLater(rig.app.stopLiveFeed(kBandId), completes);
      await expectLater(rig.app.startLiveFeed(kBandId), completes);
      expect(() => rig.app.retainLiveHrView(), returnsNormally);
      expect(() => rig.app.releaseLiveHrView(), returnsNormally);
      expect(() => rig.app.setMovementSamplingWindow(true), returnsNormally);
      expect(() => rig.feed(hr28Inner(rr: [800])), returnsNormally);
      expect(() => rig.app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner()), null),
          returnsNormally);
      expect(rig.app.debugAppendLiveHr(kBandId, 60, 5000), isTrue,
          reason: 'the append is not gated on dispose today');
      await settleMs(150);
      BleEngine.resetBandClaimForTest();
    });

    test('dispose with the feed and a viewer still held does not throw; the '
        'flags are left as they were (dispose does not reset them)', () async {
      final rig = G6Rig();
      await rig.app.startLiveFeed(kBandId);
      rig.app.retainLiveHrView();
      expect(() => rig.app.dispose(), returnsNormally);
      expect(rig.app.isLiveFeedOn(kBandId), isTrue);
      expect(rig.app.debugLiveOwners.visibleLiveHrView, isTrue);
      BleEngine.resetBandClaimForTest();
    });

    test('dispose twice: the only failure is ChangeNotifier\'s own '
        '"disposed more than once" FlutterError, nothing from the live state',
        () {
      final app = AppState.forTesting();
      app.dispose();
      Object? thrown;
      try {
        app.dispose();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<FlutterError>());
    });
  });
}
