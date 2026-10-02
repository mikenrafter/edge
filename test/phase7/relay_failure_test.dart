// Phase 7 failure injection — the native Android relay.
// A write that never answers, a disconnect mid-rhythm, a duplicate post, a
// skewed post time, a process restart, a lost Notification-access grant and a
// bridge that does not answer. Each ends with the latches cleared and no
// second buzz for one post.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _nowMs = 1000000;

Map<String, Object?> _post({
  String key = 'k1',
  int posted = _nowMs,
  String category = 'msg',
  String kind = 'post',
}) => {
  'category': category,
  'package': 'com.example',
  'keyHash': key,
  'kind': kind,
  'postTimeMs': posted,
  'receiptTimeMs': _nowMs,
  'interruptionFilter': 1,
  'ringerMode': 2,
  'ongoing': false,
  'groupSummary': false,
};

Map<String, Object?> _policy({bool connected = true, String fallback = 'none'}) => {
  'enabled': true,
  'dnd': false,
  'respectDnd': true,
  'allowDuringDnd': false,
  'ringer': 'normal',
  'includeVibrate': true,
  'includeSilent': false,
  'connected': connected,
  'fallback': fallback,
  'worn': 'worn',
  'onlyWhileWorn': false,
  'packages': ['com.example'],
  'staleAfterMs': 30000,
};

class _Rig {
  _Rig({
    AlertDeliveryLedger? ledger,
    this.buzzImpl,
    this.sequenceImpl,
    this.connected = true,
    this.fallback = 'none',
    this.phoneOk = true,
  }) : ledger = ledger ?? MemoryAlertDeliveryLedger() {
    controller = RelayController(
      dispatcher: AlertDispatcher(
        phone: () async => phoneOk,
        band: () async => false,
        isConnected: () => connected,
        now: () => DateTime.fromMillisecondsSinceEpoch(_nowMs),
        ledger: this.ledger,
        transportTimeout: const Duration(milliseconds: 60),
      ),
      buzz: (p) async {
        buzzes++;
        return buzzImpl == null ? true : buzzImpl!();
      },
      phone: () async {
        phones++;
        return phoneOk;
      },
      policy: (_) => _policy(connected: connected, fallback: fallback),
      nowMs: () => _nowMs,
      playSequence: sequenceImpl,
    );
  }
  final AlertDeliveryLedger ledger;
  final Future<bool> Function()? buzzImpl;
  final Future<bool> Function(BuzzSequence)? sequenceImpl;
  bool connected;
  String fallback;
  bool phoneOk;
  int buzzes = 0, phones = 0;
  late final RelayController controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('write timeout and disconnect', () {
    test('a band write that never answers frees the in-flight latch and a '
        'later post still buzzes', () async {
      var first = true;
      final r = _Rig(buzzImpl: () {
        if (first) {
          first = false;
          return Completer<bool>().future; // the GATT write never returns
        }
        return Future.value(true);
      });
      final a = await r.controller.handleMetadata(_post(key: 'a'));
      expect(a.suppression, 'deliveryUnconfirmed');
      expect(r.controller.busy, isFalse);
      final b = await r.controller.handleMetadata(_post(key: 'b', posted: _nowMs + 1));
      expect(b.targets, ['band']);
    });

    test('a disconnect during the rhythm is a failed delivery with no phone '
        'fallback unless the user chose one', () async {
      final r = _Rig(sequenceImpl: (_) async => false);
      final out = await r.controller.handleMetadata(_post());
      expect(out.targets, isEmpty);
      expect(out.suppression, 'deliveryFailed');
      expect(r.phones, 0);
      expect(r.controller.busy, isFalse);
    });

    test('band unavailable with the opted-in fallback: one phone alert, no '
        'band write', () async {
      final r = _Rig(connected: false, fallback: 'phoneIfBandUnavailable');
      final out = await r.controller.handleMetadata(_post());
      expect(out.targets, ['phone']);
      expect((r.buzzes, r.phones), (0, 1));
    });

    test('the band write throwing is a failed delivery, latch cleared',
        () async {
      final r = _Rig(buzzImpl: () async => throw StateError('gatt error'));
      final out = await r.controller.handleMetadata(_post());
      expect(out.suppression, 'deliveryFailed');
      expect(r.controller.busy, isFalse);
    });
  });

  group('duplicate, clock skew, restart', () {
    test('two concurrent posts of one key buzz once', () async {
      final r = _Rig();
      await Future.wait([
        r.controller.handleMetadata(_post()),
        r.controller.handleMetadata(_post()),
      ]);
      expect(r.buzzes, 1);
    });

    test('a post stamped far in the future (skewed phone clock) is refused',
        () async {
      final r = _Rig();
      final out = await r.controller.handleMetadata(_post(posted: _nowMs + 3600000));
      expect(out.suppression, 'stale');
      expect(r.buzzes, 0);
    });

    test('a post older than the stale window is refused, not replayed',
        () async {
      final r = _Rig();
      final out = await r.controller.handleMetadata(_post(posted: _nowMs - 600000));
      expect(out.suppression, 'stale');
      expect(r.buzzes, 0);
    });

    test('process restart: the new process sees the same still-posted '
        'notification and does not buzz it again', () async {
      final shared = MemoryAlertDeliveryLedger(); // stands in for SQLite
      final before = _Rig(ledger: shared);
      await before.controller.handleMetadata(_post());
      expect(before.buzzes, 1);
      final after = _Rig(ledger: shared); // new process: empty live-key set
      await after.controller.listenerConnected([_post()]);
      expect(after.buzzes, 0);
    });

    test('a genuine repost (new post time) after a removal buzzes again',
        () async {
      final r = _Rig();
      await r.controller.handleMetadata(_post());
      await r.controller.handleMetadata(_post(kind: 'remove'));
      await r.controller.handleMetadata(_post(posted: _nowMs + 5));
      expect(r.buzzes, 2);
    });
  });

  group('permission loss and the platform bridge', () {
    const channel = MethodChannel('openstrap/notification_relay');
    late bool granted;
    late bool answers;

    setUp(() {
      granted = true;
      answers = true;
      SharedPreferences.setMockInitialValues({'notif_relay_enabled': true});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) {
        if (!answers) return Completer<Object?>().future;
        return Future.value(c.method == 'isPermissionGranted'
            ? granted
            : c.method == 'activeMetadata'
                ? <Object?>[]
                : null);
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    NotificationRelay relay() => NotificationRelay(
          buzz: () async {},
          isConnected: () => true,
          debugSupported: true,
          nativeTimeout: const Duration(milliseconds: 50),
        );

    test('revoking Notification access mid-session clears every latch and '
        'stops listening', () async {
      final r = relay();
      await r.bootstrap();
      expect(r.active, isTrue);
      granted = false;
      expect(await r.refreshPermission(), isFalse);
      expect(r.active, isFalse);
      expect(r.controller.listening, isFalse);
      expect(r.controller.busy, isFalse);
      final late = await r.controller.handleMetadata(_post(key: 'later'));
      expect(late.suppression, 'notListening');
      r.dispose();
    });

    test('a bridge that does not answer is not a revocation: the last known '
        'grant is kept', () async {
      final r = relay();
      await r.bootstrap();
      answers = false;
      expect(await r.refreshPermission(), isTrue);
      expect(r.controller.listening, isTrue);
      r.dispose();
    });

    test('disarming while the bridge is silent still clears the controller\'s '
        'latches', () async {
      final r = relay();
      await r.bootstrap();
      answers = false;
      await r.setEnabled(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(r.controller.listening, isFalse,
          reason: 'our own state does not wait for the platform');
      r.dispose();
    });

    test('destroyed service: the listener state resets, and a reconnect '
        'restores listening', () async {
      final r = relay();
      await r.bootstrap();
      await r.controller.stop('destroyed');
      expect(r.controller.listening, isFalse);
      await r.controller.listenerConnected([]);
      expect(r.controller.listening, isTrue);
      r.dispose();
    });
  });
}
