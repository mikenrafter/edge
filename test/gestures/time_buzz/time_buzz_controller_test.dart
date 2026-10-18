// Tell the time at the real gesture seam: GestureController over a real
// GestureDispatcher (real once-ever claims over sqflite_ffi), a real
// AlertDispatcher, a real HapticsService and a recording band.
//
// Pinned here (the pure parts are in the sibling files):
//   * a live double tap with tellTime mapped plays the time on the band as the
//     vocabulary phrases of toBuzzChunks, in order: on an MG short = buzz14
//     [14]x1, long = buzz47x2 [47]x2, click = click1 [1]x1; on a band with no
//     profile one held buzz per element (long > short > click);
//   * the whole time is written even when it is longer than one BuzzSequence
//     (12:44 PM is 15 commands) and even when its runtime is past the 10 s cap
//     for compiled haptics (a cap fallback would write other phrases);
//   * rule 4 of the haptic budget: no command left means no action and no
//     write; rules 1 and 5: with room to start, the gesture plays to its end
//     past the limit and the ledger does not count past it;
//   * a band that takes no write makes the action a FAILED one, recorded as a
//     failed gesture, not a silent success.
//
// The time comes from GestureController(now:), the injectable clock. Real
// clock for waits: the recording band answers each command with the band's
// "ended" event 2 ms later, so only the 1 s pauses of the time itself are slow.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart'
    show GestureOutcome, GestureStatus;
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/state/gesture_controller.dart';

import '../../support/app_state_gesture_harness.dart';

const _db = 'time_buzz_controller.db';

const _long = '[47]x2';
const _short = '[14]x1';
const _click = '[1]x1';

List<String> _x(String phrase, int n) => List.filled(n, phrase);

/// A recording band. [gen] 'gen5' is the MG vocabulary (Maverick patterns),
/// null a band with no profile (held buzzes). [writeOk] false refuses every
/// write.
class _Band implements BandHapticsPort {
  _Band(this.gen, {this.writeOk = true});
  final String? gen;
  bool writeOk;
  late HapticsService haptics;
  bool _gone = false;

  /// `[effects]xloop` of every pattern written, in order.
  final patterns = <String>[];

  /// The hold of every plain buzz written, in order.
  final holds = <int>[];

  @override
  bool get isConnected => true;
  @override
  String? get generation => gen;

  void _ended() {
    Timer(const Duration(milliseconds: 2), () {
      if (_gone) return;
      final now = DateTime.now();
      haptics.onBandEvent(StrapEvent(
        eventId: 100,
        tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
        receivedAt: now,
        hex: '',
        deviceId: '',
      ));
    });
  }

  @override
  Future<bool> buzzBand({int holdMs = 0}) async {
    if (!writeOk) return false;
    holds.add(holdMs);
    _ended();
    return true;
  }

  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async {
    if (!writeOk) return false;
    patterns.add('${effects}x$loop');
    _ended();
    return true;
  }

  void dispose() => _gone = true;
}

class _Host {
  _Host({String? gen = 'gen5', bool writeOk = true}) {
    band = _Band(gen, writeOk: writeOk);
    haptics = HapticsService(port: band, allowLong: () => false);
    band.haptics = haptics;
    ecg = SpyEcg(<String>[]);
    alerts = AlertDispatcher(
      phone: () async => false,
      band: () async => true,
      isConnected: () => true,
      bandQueueWait: const Duration(seconds: 5),
      ledger: MemoryAlertDeliveryLedger(),
    );
    controller = GestureController(
      settings: settings,
      haptics: haptics,
      deviceLab: lab,
      alertDispatcher: () => alerts,
      ecg: () => ecg,
      ecgSupported: () => false,
      clockRef: () => null,
      log: (_) {},
      onMarkMoment: (e) async {},
      onWorkoutToggle: (e) async {},
      recordEcgSession: (r) async {},
      loadPatterns: () async => HapticPatternStore.decodeSeeded(null),
      readCueAssignments: () => '',
      readFailures: () => '',
      writeFailures: (json) async {},
      now: () => at,
    );
  }

  /// The injected local clock.
  DateTime at = DateTime(2026, 10, 7, 15, 8);

  final settings = GestureSettings();
  final lab = DeviceLabLog();
  late final _Band band;
  late final HapticsService haptics;
  late final SpyEcg ecg;
  late final AlertDispatcher alerts;
  late final GestureController controller;
  int _seq = 0;

  StrapEvent doubleTap() {
    final now = DateTime.now();
    return StrapEvent(
      eventId: 14,
      tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
      tsSubsec: 100 + 37 * ++_seq,
      receivedAt: now,
      hex: '',
      deviceId: 'band',
    );
  }

  /// Leave the band [left] commands in the window.
  void spend({required int left}) {
    final n = haptics.commandsLeft - left;
    if (n > 0) haptics.ledger.record(n, clock.now());
  }

  void dispose() {
    band.dispose();
    settings.dispose();
    ecg.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
  });
  tearDown(() => deriveDbTearDown(_db));

  late _Host h;
  late ActionChannel channel;
  Future<_Host> host({String? gen = 'gen5', bool writeOk = true}) async {
    // The native channel answers true: an action wrongly sent there would
    // look like a success.
    channel = ActionChannel();
    addTearDown(channel.dispose);
    h = _Host(gen: gen, writeOk: writeOk);
    addTearDown(h.dispose);
    addTearDown(h.controller.dispose);
    await h.settings.setDoubleTapActions({DeviceAction.tellTime});
    return h;
  }

  Future<void> played(int commands) async {
    await until(() => h.band.patterns.length + h.band.holds.length >= commands,
        within: const Duration(seconds: 12), what: '$commands commands written');
    await settleMs(100); // and nothing more
  }

  group('on an MG (the band\'s measured vocabulary)', () {
    test('15:08 count: three long phrases, then a click', () async {
      await host();
      final out = await h.controller.handle(h.doubleTap());
      expect(out.single.action, DeviceAction.tellTime);
      expect(out.single.status, GestureStatus.ran);
      await played(4);
      expect(h.band.patterns, [..._x(_long, 3), _click]);
      expect(h.band.holds, isEmpty);
      expect(h.controller.failures.all, isEmpty);
      expect(channel.performed, isEmpty, reason: 'in-app: never native');
    });

    test('03:00 count: three short phrases and nothing else (no pause, no '
        'clicks)', () async {
      await host();
      h.at = DateTime(2026, 10, 7, 3, 0);
      await h.controller.handle(h.doubleTap());
      await played(3);
      expect(h.band.patterns, _x(_short, 3));
    });

    test('12:44 count is 15 commands, more than one sequence holds, and runs '
        'past the 10 s compiled-haptics cap: all 15 are the right phrases',
        () async {
      await host();
      h.at = DateTime(2026, 10, 7, 12, 44);
      await h.controller.handle(h.doubleTap());
      await played(15);
      expect(h.band.patterns, [..._x(_long, 12), ..._x(_click, 3)]);
    });

    test('23:59 count: 11 long and 4 clicks (:53 is never rolled into the '
        'next hour)', () async {
      await host();
      h.at = DateTime(2026, 10, 7, 23, 59);
      await h.controller.handle(h.doubleTap());
      await played(15);
      expect(h.band.patterns, [..._x(_long, 11), ..._x(_click, 4)]);
    });

    test('binary 15:08: 0011 as short short long long, PM as a long, then '
        'the click', () async {
      await host();
      await h.settings.setTimeBuzzMode(TimeBuzzMode.binary);
      await h.controller.handle(h.doubleTap());
      await played(6);
      expect(h.band.patterns,
          [..._x(_short, 2), ..._x(_long, 2), _long, _click]);
    });

    test('morse 15:08: 3 is ...--, P is .--., then the click', () async {
      await host();
      await h.settings.setTimeBuzzMode(TimeBuzzMode.morse);
      await h.controller.handle(h.doubleTap());
      await played(10);
      expect(h.band.patterns, [
        ..._x(_short, 3), ..._x(_long, 2), // 3
        _short, _long, _long, _short, //     P
        _click,
      ]);
    });

    test('the clock is read for each tap: the next tap tells the new time',
        () async {
      await host();
      await h.controller.handle(h.doubleTap());
      await played(4);
      h.band.patterns.clear();
      h.at = DateTime(2026, 10, 7, 4, 0);
      await h.controller.handle(h.doubleTap());
      await played(4);
      expect(h.band.patterns, _x(_short, 4));
    });
  });

  group('on a band with no haptic profile (a 4.0)', () {
    test('15:08 count: one held buzz per element, long > click, no pattern '
        'writes', () async {
      await host(gen: null);
      await h.controller.handle(h.doubleTap());
      await played(4);
      expect(h.band.patterns, isEmpty);
      expect(h.band.holds, hasLength(4));
      final holds = h.band.holds;
      expect(holds[1], holds[0]);
      expect(holds[2], holds[0]);
      expect(holds[0], greaterThan(holds[3]), reason: 'long > click');
    });

    test('binary 15:08: long > short > click in how long each is held',
        () async {
      await host(gen: null);
      await h.settings.setTimeBuzzMode(TimeBuzzMode.binary);
      await h.controller.handle(h.doubleTap());
      await played(6);
      final d = h.band.holds; // S S L L L C
      expect(d, hasLength(6));
      expect(d[2], greaterThan(d[0]));
      expect(d[0], greaterThan(d[5]));
    });
  });

  group('the haptic budget', () {
    test('rule 4: no command left means no action and no band write, and '
        'nothing is reported as failed', () async {
      await host();
      h.spend(left: 0);
      List<GestureOutcome>? out;
      unawaited(h.controller.handle(h.doubleTap()).then((o) => out = o));
      await settleMs(400);
      expect(out, isEmpty, reason: 'answered at once, with nothing');
      expect(h.band.patterns, isEmpty);
      expect(h.band.holds, isEmpty);
      expect(h.controller.failures.all, isEmpty);
    });

    test('rules 1 and 5: with one command left the gesture starts and plays '
        'to its end (4 commands), and the ledger does not count past the '
        'limit', () async {
      await host();
      h.spend(left: 1);
      final out = await h.controller.handle(h.doubleTap());
      expect(out.single.status, GestureStatus.ran);
      await played(4);
      expect(h.band.patterns, [..._x(_long, 3), _click],
          reason: 'never half a time: a partial time says the wrong hour');
      expect(h.haptics.commandsLeft, 0, reason: 'the limit, not more');
    });
  });

  group('a band that takes no write', () {
    test('the action FAILED: reported and recorded as a failed gesture, '
        'never a silent success', () async {
      await host(writeOk: false);
      final out = await h.controller.handle(h.doubleTap());
      expect(out.single.status, GestureStatus.failed);
      expect(channel.performed, isEmpty, reason: 'in-app: never native');
      expect(h.controller.failures.all, hasLength(1));
      expect(h.controller.failures.all.single.reason, startsWith('tell_time'));
    });
  });
}
