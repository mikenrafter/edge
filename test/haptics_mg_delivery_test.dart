// Delivery on a WHOOP 5.0 MG band (app_state). The
// delivery helper lives in HapticsService (haptics_service_test.dart drives it
// against a fake and a virtual band); this file keeps the seam's own tests and
// the guards on which AppState call sites hand their delivery to the service.
//
// The behaviour sits in a seam in lib/haptics/haptic_player.dart that the
// service hands its band primitives to. Which AppState call sites hand their
// delivery to the service is run against a recording service (AppState
// .forTesting(haptics:)); a few paths that need a live session are still read:
//
//   Future<BuzzDelivery> deliverBandSequence(BuzzSequence s, {
//     required HapticDeviceProfile? profile,   // null = gen4 / no profile
//     required Future<bool> Function() buzz,
//     Future<bool> Function(int holdMs)? buzzForDuration,
//     required Future<bool> Function(List<int> effects, int loop) writePattern,
//     required Future<bool> Function(Duration timeout) waitEnded,
//     required bool Function() isConnected,
//   })
//   Duration bandSequenceTimeout(BuzzSequence s, HapticDeviceProfile? profile)
//
// With a profile the sequence plays as planForTaps(s, profile) commands; with
// none (gen4), or when no plan compiles, it plays today's per-tap buzz.

import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/band_queue.dart'
    show BandCommandLedger, BandJobToken, kBandBuzzPlayback;
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'support/dart_source_lexical.dart';
import 'support/app_state_derive_harness.dart' show deriveDbSetUp, deriveDbTearDown;

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

const _db = 'haptics_mg_delivery.db';

/// A band that is always there and speaks gen5.
class _Port implements BandHapticsPort {
  @override
  bool get isConnected => true;
  @override
  String? get generation => 'gen5';
  @override
  Future<bool> buzzBand({int holdMs = 0}) async => true;
  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async => true;
}

/// The service every producer is handed. It records what it was asked and
/// answers `complete`; the real queue, ledger and port stay behind it.
class _RecordingHaptics extends HapticsService {
  _RecordingHaptics() : super(port: _Port(), allowLong: () => false);
  final events = <String>[];
  final delivered = <BuzzSequence>[];
  final timeoutFor = <BuzzSequence>[];
  final heard = <(int, bool)>[];

  @override
  Future<BuzzDelivery> deliver(BuzzSequence s,
      {void Function(HapticPlayStart)? onStart}) async {
    events.add('deliver');
    delivered.add(s);
    return BuzzDelivery.complete;
  }

  @override
  Future<BuzzDelivery> runJob(
    int commands,
    Future<BuzzDelivery> Function(BandJobToken job) job, {
    Duration? timeout,
    Duration settle = kBandBuzzPlayback,
  }) async {
    events.add('runJob:$commands');
    return BuzzDelivery.complete;
  }

  @override
  Duration sequenceTimeout(BuzzSequence s) {
    timeoutFor.add(s);
    return const Duration(seconds: 12);
  }

  @override
  Future<bool> buzzForDuration(int holdMs) async {
    events.add('hold:$holdMs');
    return true;
  }

  @override
  void onBandEvent(StrapEvent e) => heard.add((e.eventId, e.isLive));

  @override
  void beginLab() => events.add('beginLab');
  @override
  void endLab() => events.add('endLab');
  @override
  Future<bool> runLab(Future<void> Function() body) async {
    events.add('runLab');
    await body();
    return true;
  }
}

/// A real AppState on an engine with a fake link, handed the recording
/// service. Anything a producer writes to the link itself is counted.
class _Wired {
  _Wired() {
    app = AppState.forTesting(haptics: svc);
    app.engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      listening: true,
      onWrite: (Uint8List frame) async {
        linkWrites++;
        return true;
      },
    );
    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', '4C2248092');
    app.engine.state.generation = 'gen5';
    app.engine.state.connection = 'connected';
  }

  final svc = _RecordingHaptics();
  late final AppState app;
  int linkWrites = 0;

  /// A band event [id] stamped [at] on the strap clock, through the engine's
  /// live event path.
  void event(int id, DateTime at) {
    final ms = at.millisecondsSinceEpoch;
    final inner = Uint8List(12);
    final v = ByteData.sublistView(inner);
    inner[0] = PacketType.event;
    inner[1] = 0x09;
    v.setUint16(2, id, Endian.little);
    v.setUint32(4, ms ~/ 1000, Endian.little);
    v.setUint16(8, (ms % 1000) * 32768 ~/ 1000, Endian.little);
    app.engine.debugProcessImmediateFrame(Frame(inner, true, true));
  }
}

/// Records which band primitive each delivery used.
class _Rig {
  _Rig(this.async);
  final FakeAsync async;
  bool connected = true;
  final buzzes = <int?>[]; // per-tap writes (null = plain buzz())
  final patterns = <String>[];
  final patternAt = <int>[];
  var waits = 0;
  final waitTimeouts = <Duration>[];

  BuzzDelivery? out;

  void deliver(BuzzSequence s, {required HapticDeviceProfile? profile}) {
    deliverBandSequence(
      s,
      profile: profile,
      buzz: () async {
        buzzes.add(null);
        return true;
      },
      buzzForDuration: (hold) async {
        buzzes.add(hold);
        return true;
      },
      writePattern: (effects, loop) async {
        patterns.add('$effects x$loop');
        patternAt.add(async.elapsed.inMilliseconds);
        return true;
      },
      waitEnded: (timeout) async {
        waits++;
        waitTimeouts.add(timeout);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return true;
      },
      isConnected: () => connected,
    ).then((v) => out = v);
    async.elapse(const Duration(minutes: 2));
  }
}

/// Two half-second holds with a 3-unit release gap.
final _twoHolds = BuzzSequence([0, 875], durationsMs: [500, 500]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('gen5 with a profile: the compiled plan is written', () {
    test('Maverick commands from planForTaps, never per-tap buzzes', () {
      fakeAsync((async) {
        final rig = _Rig(async)..deliver(_twoHolds, profile: _mg);
        final plan = planForTaps(_twoHolds, _mg)!;
        expect(rig.out, BuzzDelivery.complete);
        expect(rig.buzzes, isEmpty);
        expect(rig.patterns, [
          for (final s in plan.steps) '${s.phrase.effects} x${s.phrase.loop}',
        ]);
      });
    });

    test('a multi-step plan waits for the band between its commands', () {
      fakeAsync((async) {
        final plan = planForTaps(_twoHolds, _mg)!;
        final rig = _Rig(async)..deliver(_twoHolds, profile: _mg);
        expect(plan.steps.length, greaterThan(1));
        expect(rig.waits, plan.steps.length - 1);
        // Ended arrives 500 ms after each wait starts; then the step's delay.
        expect(rig.patternAt[1], 500 + plan.steps[1].delayMs);
      });
    });

    test('the unstable 100 ms gap row is always on the table', () {
      fakeAsync((async) {
        // N4mf R1 N4mf: a 1-unit silence is only measured on the unstable
        // 100 ms gap row.
        final s = BuzzSequence([0, 625], durationsMs: [500, 500]);
        final rig = _Rig(async)..deliver(s, profile: _mg);
        expect(rig.out, BuzzDelivery.complete);
        expect(rig.patterns, hasLength(2));
        expect(rig.patternAt[1], 500 + 100);
      });
    });

    test('not connected -> rejected and nothing written', () {
      fakeAsync((async) {
        final rig = _Rig(async)..connected = false;
        rig.deliver(_twoHolds, profile: _mg);
        expect(rig.out, BuzzDelivery.rejected);
        expect(rig.patterns, isEmpty);
        expect(rig.buzzes, isEmpty);
      });
    });
  });

  group('gen4 (no profile): today\'s per-tap buzz, unchanged', () {
    test('each tap is a buzz of its hold; no pattern command, no waiting', () {
      fakeAsync((async) {
        final rig = _Rig(async)..deliver(_twoHolds, profile: null);
        expect(rig.out, BuzzDelivery.complete);
        expect(rig.buzzes, [500, 500]);
        expect(rig.patterns, isEmpty);
        expect(rig.waits, 0);
      });
    });

    test('not connected -> rejected', () {
      fakeAsync((async) {
        final rig = _Rig(async)..connected = false;
        rig.deliver(_twoHolds, profile: null);
        expect(rig.out, BuzzDelivery.rejected);
        expect(rig.buzzes, isEmpty);
      });
    });
  });

  group('bandSequenceTimeout covers the whole plan', () {
    test('without a profile it is the sequence\'s own transport timeout', () {
      expect(bandSequenceTimeout(_twoHolds, null), _twoHolds.transportTimeout);
    });

    test('with a profile: max(transport, felt max span + 2 s per step + 1 s)',
        () {
      for (final s in [
        _twoHolds,
        BuzzSequence([0]),
        BuzzSequence([0, 1600, 3200], durationsMs: [1500, 1500, 1500]),
        BuzzSequence([0, 1900], durationsMs: [12 * 125, 12 * 125]),
      ]) {
        final plan = planForTaps(s, _mg)!;
        final feltMs = timeline(plan.feltMax).length * _mg.unitMs;
        final planned = Duration(
          milliseconds: feltMs + 2000 * plan.steps.length + 1000,
        );
        final want =
            planned > s.transportTimeout ? planned : s.transportTimeout;
        expect(bandSequenceTimeout(s, _mg), want, reason: '$s');
        expect(
          bandSequenceTimeout(s, _mg),
          greaterThanOrEqualTo(s.transportTimeout),
        );
      }
    });

    test('a plan with long waits is given more than the tap time alone', () {
      // Three half-second holds 2 s apart compile to several commands, each
      // with its own allowance for the band's reply. (Three quick taps would
      // compile to one approximate command: the command penalty prefers it.)
      final s = BuzzSequence([0, 2000, 4000], durationsMs: [500, 500, 500]);
      final plan = planForTaps(s, _mg)!;
      expect(plan.steps.length, greaterThanOrEqualTo(2));
      expect(bandSequenceTimeout(s, _mg),
          greaterThanOrEqualTo(Duration(seconds: 2 * plan.steps.length + 1)));
    });
  });

  group('a saved rule: baked plan, notes, then taps', () {
    final baked = [
      BakedStep(effects: const [47], loop: 1, delayMs: 0),
      BakedStep(effects: const [14], loop: 1, delayMs: 300),
    ];
    // The taps are deliberately unlike the notes and the baked plan, so what
    // was played says which one the delivery used.
    BuzzSequence rule({
      String? notes,
      String? id,
      List<BakedStep>? plan,
    }) =>
        BuzzSequence(
          const [0, 875],
          durationsMs: const [500, 500],
          notes: notes,
          profileId: id,
          profileVersion: id == null ? null : 1,
          bakedSteps: plan,
        );

    test('baked steps are written as stored, no recompile', () {
      fakeAsync((async) {
        final rig = _Rig(async)
          ..deliver(rule(notes: 'N4mf', id: _mg.id, plan: baked), profile: _mg);
        expect(rig.out, BuzzDelivery.complete);
        expect(rig.buzzes, isEmpty);
        expect(rig.patterns, ['[47] x1', '[14] x1']);
        expect(rig.waits, 1);
        // Ended arrives 500 ms after the wait starts, then the stored delay.
        expect(rig.patternAt, [0, 500 + 300]);
      });
    });

    test('baked steps a later vocabulary no longer has are still written', () {
      fakeAsync((async) {
        final odd = [BakedStep(effects: const [99, 98], loop: 3, delayMs: 0)];
        final rig = _Rig(async)
          ..deliver(rule(id: _mg.id, plan: odd), profile: _mg);
        expect(rig.out, BuzzDelivery.complete);
        expect(rig.patterns, ['[99, 98] x3']);
      });
    });

    test('the wait timeout comes from the matching phrase, else 3000 ms', () {
      fakeAsync((async) {
        final mixed = [
          BakedStep(effects: const [47], loop: 1, delayMs: 0),
          BakedStep(effects: const [99], loop: 1, delayMs: 100),
          BakedStep(effects: const [14], loop: 1, delayMs: 0),
        ];
        final rig = _Rig(async)
          ..deliver(rule(id: _mg.id, plan: mixed), profile: _mg);
        final buzz47 = _mg.phrases.firstWhere((p) => p.id == 'buzz47');
        expect(rig.waitTimeouts, [
          Duration(milliseconds: buzz47.unitsMax * _mg.unitMs + 1500),
          const Duration(milliseconds: 3000),
        ]);
        expect(rig.patternAt[1], 500 + 100);
        expect(rig.patternAt[2], 500 + 100 + 500 + 0);
      });
    });

    test('the baked plan wins over the notes and the taps', () {
      fakeAsync((async) {
        final one = [BakedStep(effects: const [14], loop: 2, delayMs: 0)];
        final rig = _Rig(async)
          ..deliver(rule(notes: 'N4ff R6 N4f', id: _mg.id, plan: one),
              profile: _mg);
        expect(rig.patterns, ['[14] x2']);
      });
    });

    test('notes made of mf only (from taps) compile without loudness', () {
      fakeAsync((async) {
        // A half-second hold is N4mf; no phrase feels mf for four cells, but
        // taps carry no loudness, so it is one exact command.
        final rig = _Rig(async)
          ..deliver(rule(notes: 'N4mf', id: _mg.id), profile: _mg);
        expect(rig.patterns, hasLength(1));
      });
    });

    test('a baked plan for another profile is ignored: the taps compile', () {
      fakeAsync((async) {
        final odd = [BakedStep(effects: const [99], loop: 1, delayMs: 0)];
        final rig = _Rig(async)
          ..deliver(rule(notes: 'N4ff', id: 'some-other-band', plan: odd),
              profile: _mg);
        final plan = planForTaps(_twoHolds, _mg)!;
        expect(rig.patterns, [
          for (final s in plan.steps) '${s.phrase.effects} x${s.phrase.loop}',
        ]);
      });
    });

    test('notes without a baked plan are compiled', () {
      fakeAsync((async) {
        final rig = _Rig(async)
          ..deliver(rule(notes: 'N4ff R4 N4f', id: _mg.id), profile: _mg);
        expect(rig.patterns, ['[47] x1', '[14] x1']);
        expect(rig.patternAt[1], 500 + 300);
      });
    });

    test('notes for another profile are ignored', () {
      fakeAsync((async) {
        final rig = _Rig(async)
          ..deliver(rule(notes: 'N4ff R6 N4f', id: 'some-other-band'),
              profile: _mg);
        final plan = planForTaps(_twoHolds, _mg)!;
        expect(rig.patterns, [
          for (final s in plan.steps) '${s.phrase.effects} x${s.phrase.loop}',
        ]);
      });
    });

    test('no profile: baked and notes are ignored, per-tap buzzes play', () {
      fakeAsync((async) {
        final rig = _Rig(async)
          ..deliver(rule(notes: 'N4ff', id: _mg.id, plan: baked),
              profile: null);
        expect(rig.buzzes, [500, 500]);
        expect(rig.patterns, isEmpty);
      });
    });

    test('a baked plan that is not connected is rejected, nothing written', () {
      fakeAsync((async) {
        final rig = _Rig(async)..connected = false;
        rig.deliver(rule(id: _mg.id, plan: baked), profile: _mg);
        expect(rig.out, BuzzDelivery.rejected);
        expect(rig.patterns, isEmpty);
      });
    });

    test('taps over the runtime cap with no plan fall back to per-tap buzzes',
        () {
      fakeAsync((async) {
        final long = BuzzSequence([for (var i = 0; i < 7; i++) i * 1900]);
        expect(planForTaps(long, _mg), isNull);
        final rig = _Rig(async)..deliver(long, profile: _mg);
        expect(rig.patterns, isEmpty);
        expect(rig.buzzes, hasLength(7));
      });
    });

    test('bandSequenceTimeout covers a baked plan', () {
      final mixed = [
        BakedStep(effects: const [47], loop: 1, delayMs: 0),
        BakedStep(effects: const [99], loop: 1, delayMs: 100),
        BakedStep(effects: const [14], loop: 1, delayMs: 700),
      ];
      final s = rule(id: _mg.id, plan: mixed);
      // 47: 4 units, unknown: 3000 ms, 14: 4 units; plus the delays.
      final feltMs = 4 * 125 + 3000 + 4 * 125 + 100 + 700;
      final planned = Duration(milliseconds: feltMs + 2000 * 3 + 1000);
      expect(bandSequenceTimeout(s, _mg),
          planned > s.transportTimeout ? planned : s.transportTimeout);
      expect(bandSequenceTimeout(s, null), s.transportTimeout);
    });

    test('bandSequenceTimeout for notes is the compiled notes plan', () {
      final s = rule(notes: 'N4ff R6 N4f', id: _mg.id);
      final plan = compile(PatternTranscript.parseCode('N4ff R6 N4f').entries,
          _mg)!;
      final planned = Duration(
          milliseconds: plan.runtimeMs + 2000 * plan.steps.length + 1000);
      expect(bandSequenceTimeout(s, _mg),
          planned > s.transportTimeout ? planned : s.transportTimeout);
    });
  });

  // The delivery helper, the queue, the ledger and the ended signal
  // moved from AppState into HapticsService (lib/haptics/haptics_service.dart).
  // What those guards pinned inside the helper is now a behaviour test in
  // haptics_service_test.dart; what stays here is which AppState call sites
  // hand their delivery to the service.
  // Every producer of a band haptic, driven through the real AppState against
  // one recording HapticsService (AppState.forTesting(haptics:)). The service
  // records instead of playing, so a producer that writes to the band by itself
  // shows up as a link write the service never saw.
  group('every producer hands its delivery to the one service', () {
    late _Wired w;
    setUp(() async {
      BleEngine.resetBandClaimForTest();
      await deriveDbSetUp(_db);
      w = _Wired();
    });
    tearDown(() async {
      w.app.dispose();
      BleEngine.resetBandClaimForTest();
      await deriveDbTearDown(_db);
    });

    final seq = BuzzSequence([0, 875], durationsMs: [500, 500]);
    AlertRule rule({BuzzSequence? saved}) => AlertRule(
          id: 'mg_probe',
          kind: 'buzzPreview',
          destinations: AlertRule.band,
          executionMode: AlertExecutionMode.phoneLive,
          staleAfter: const Duration(seconds: 10),
          channelPolicyId: 'buzz_preview',
          buzzSequence: saved,
        );

    test('the preview delivers through the service and takes its deadline '
        'from it', () async {
      expect(await w.app.previewBuzzSequence(seq), isTrue);
      expect(w.svc.delivered, [seq]);
      expect(w.svc.timeoutFor, contains(seq));
      expect(w.linkWrites, 0);
    });

    test('a rule\'s saved rhythm goes through the dispatcher\'s sequence '
        'transport into the service, with the service\'s deadline', () async {
      final now = DateTime.now();
      final out = await w.app.alertDispatcher.dispatch(
        rule(saved: seq),
        eventId: 'saved:${now.microsecondsSinceEpoch}',
        sourceTime: now,
        historical: false,
      );
      expect(out.targets, ['band']);
      expect(w.svc.delivered, [seq]);
      expect(w.svc.timeoutFor, contains(seq));
      expect(w.linkWrites, 0);
    });

    test('a rule with no rhythm plays the dispatcher\'s default band buzz as '
        'one queue job', () async {
      final now = DateTime.now();
      final out = await w.app.alertDispatcher.dispatch(
        rule(),
        eventId: 'plain:${now.microsecondsSinceEpoch}',
        sourceTime: now,
        historical: false,
      );
      expect(out.targets, ['band']);
      expect(w.svc.events, ['runJob:1']);
      expect(w.linkWrites, 0);
    });

    test('a numbered pattern (Tasker) is one queue job', () async {
      // Quiet hours would hold it at night; the clock is not the subject.
      await (await NotificationPrefs.load()).copyWith(quietEnabled: false).save();
      await w.app.taskerBridge.buzzPattern(1);
      expect(w.svc.events, ['runJob:1']);
      expect(w.linkWrites, 0);
    });

    test('the user-facing test buzz is one queue job', () async {
      await w.app.testBuzzPattern(1);
      expect(w.svc.events, ['runJob:1']);
      expect(w.linkWrites, 0);
    });

    test('a gesture cue is delivered by the service', () async {
      await w.app.gestureCues.confirm();
      expect(w.svc.events, contains('deliver'));
      expect(w.linkWrites, 0);
    });

    test('the notification relay is handed the queue, the delivery and its '
        'deadline', () async {
      final relay = w.app.notificationRelay;
      expect(await relay.deliverSequence!(seq), BuzzDelivery.complete);
      expect(relay.sequenceTimeout!(seq), const Duration(seconds: 12));
      expect(await relay.runBand!(2, (_) async => BuzzDelivery.complete),
          BuzzDelivery.complete);
      expect(await relay.buzzForDuration!(300), isTrue);
      expect(w.svc.events, ['deliver', 'runJob:2', 'hold:300']);
      expect(w.svc.timeoutFor, [seq]);
    });

    test('the probes count into the service\'s ledger and take its lab slot',
        () async {
      final probes = w.app.hardwareProbes;
      expect(identical(probes.ledger, w.svc.ledger), isTrue);
      probes.openLab();
      probes.closeLab();
      expect(await probes.runLab!(() async {}), isTrue);
      expect(w.svc.events, ['beginLab', 'endLab', 'runLab']);
      // The buzz probe reserves its own commands; a second record here would
      // count each buzz twice against the band's limit.
      expect(await probes.sendBuzz((_, _) {}), isTrue);
      expect(w.svc.commandsLeft, BandCommandLedger.maxCommands);
    });

    test('the strap\'s live events reach the service, late ones included '
        '(the service decides what they release)', () async {
      final now = DateTime.now();
      w.event(100, now);
      w.event(60, now);
      w.event(100, now.subtract(const Duration(minutes: 5)));
      expect(w.svc.heard, [(100, true), (60, true), (100, false)]);
    });
  });

  group('what a delivery costs the queue', () {
    test('bandSequenceCommands: the plan\'s commands on a profile, the taps '
        'without one', () {
      final plan = planForTaps(_twoHolds, _mg)!;
      expect(bandSequenceCommands(_twoHolds, _mg), plan.steps.length);
      expect(bandSequenceCommands(_twoHolds, null), 2);
      expect(bandSequenceCommands(BuzzSequence([0]), null), 1);
    });

    test('bandSequenceSettle: the last command\'s ended wait on a profile, '
        'one buzz\'s playback without one', () {
      final plan = planForTaps(_twoHolds, _mg)!;
      final last = plan.steps.last.phrase;
      expect(bandSequenceSettle(_twoHolds, _mg),
          Duration(milliseconds: last.unitsMax * _mg.unitMs + 1500));
      // The per-tap path holds the band through one buzz's playback.
      expect(bandSequenceSettle(_twoHolds, null), kBandBuzzPlayback);
    });

    test('a rule that does not compile costs its taps', () {
      // Over the 10 s cap: the per-tap path plays, one write per tap.
      final long = BuzzSequence(
        [for (var i = 0; i < 5; i++) i * 5000],
        durationsMs: List.filled(5, 3000),
      );
      expect(planForTaps(long, _mg), isNull);
      expect(bandSequenceCommands(long, _mg), 5);
      expect(bandSequenceSettle(long, _mg), kBandBuzzPlayback);
    });
  });

  group('band queue wiring (app_state)', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();
    final code = codeOnly(src);
    final svc = codeOnly(File('lib/haptics/haptics_service.dart').readAsStringSync());
    // The gesture cues live in the gesture controller.
    final gestures = File('lib/state/gesture_controller.dart').readAsStringSync();

    test('AppState builds one service, which owns the one queue and ledger',
        () {
      expect(RegExp(r'HapticsService\(').allMatches(code), hasLength(1));
      expect(code, isNot(contains('BandCommandLedger(')));
      expect(code, isNot(contains('BandHapticQueue(')));
      expect(RegExp(r'BandHapticQueue\(').allMatches(svc), hasLength(1));
    });

    test('the setting reaches the service from Prefs, once', () {
      final start = code.indexOf('late final HapticsService haptics');
      final ctor = code.substring(start, code.indexOf(');', start));
      expect(ctor, contains('allowLong: () => Prefs.allowLongHaptics'));
      expect(ctor, contains('BleEngineHapticsPort(() => engine)'));
    });

    test('runJob is the one door to the queue', () {
      expect(RegExp(r'_queue\.run\(').allMatches(svc), hasLength(1));
      expect(code, isNot(contains('.run(\n        job')));
    });

    test('the paths no test above reaches run inside a queue job', () {
      // The ECG touch counter and its failure buzz.
      // The count buzz is the gesture cues', whose delivery is a queue
      // job (compiled: haptics.deliver; no profile: haptics.runJob).
      expect(bodyOf(gestures, 'Future<bool> _ecgTapBuzz('),
          contains('cues.followUp'));
      final cues = File('lib/haptics/gesture_cues.dart').readAsStringSync();
      expect(cues, contains('haptics.deliver('));
      expect(cues, contains('haptics.runJob('));
      expect(bodyOf(gestures, 'Future<bool> _ecgTapFailBuzz('),
          contains('cues.failed'));
      // The alarm and fixed pattern of _dispatchBandAlert, and the rule
      // rhythm it plays: only reachable from a workout, a breathing session or
      // a wake, which need a live band session.
      final alert = codeOnly(
          bodyOf(src, 'Future<AlertDeliveryOutcome> _dispatchBandAlert('));
      expect(alert, contains('haptics.runJob('));
      expect(alert, contains('haptics.deliver('));
      expect(alert, isNot(contains('deliverBuzzSequence(')));
      expect(alert, contains('haptics.sequenceTimeout('));
    });

    test('the dispatcher gives the queue its time', () {
      final start = code.indexOf('late final AlertDispatcher alertDispatcher =');
      final dispatcher =
          code.substring(start, code.indexOf('AlertDispatcher debugAlertDispatcher', start));
      expect(dispatcher, contains('bandQueueWait: kBandQueueWait'));
    });

    test('every engine buzz left in AppState sits inside a queue job (or is a '
        'lab probe, which counts into the ledger itself)', () {
      final probeBuzz = src.indexOf('Future<bool> _probeBuzz(');
      final probeBuzzEnd = probeBuzz + bodyOf(src, 'Future<bool> _probeBuzz(').length;
      final probePattern = src.indexOf('Future<bool> _probePattern(');
      final probePatternEnd =
          probePattern + bodyOf(src, 'Future<bool> _probePattern(').length;
      final openers = [
        RegExp(r'\bhaptics\.runJob\('),
        RegExp(r'\b_userBuzz\('),
        // Constructor arguments handed to objects that only buzz through the
        // dispatcher or the queue (pinned in the next tests).
        RegExp(r'\bNotificationRelay\('),
        RegExp(r'\bWaterBuzzer\('),
        RegExp(r'\bMedBuzzer\('),
      ];
      final offenders = <String>[];
      for (final m in RegExp(
        r'engine\.(buzz|buzzBand|buzzMaverickPattern|runAlarm|buzzPattern)\(',
      ).allMatches(code)) {
        final inProbe = (m.start > probeBuzz && m.start < probeBuzzEnd) ||
            (m.start > probePattern && m.start < probePatternEnd);
        final enclosed = openers.any((o) => enclosedByCall(code, m.start, o));
        if (!inProbe && !enclosed) {
          offenders.add('app_state.dart:${lineOf(code, m.start)}');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    // Both rows open the pattern picker, which hands the profile on to
    // the tap sheet and the notes editor.
    test('both pattern editors are given the band\'s profile', () {
      for (final f in [
        'lib/ui2/profile/settings.dart',
        'lib/ui2/profile/band_notifications.dart',
      ]) {
        final text = File(f).readAsStringSync();
        final at = text.indexOf('showPatternPicker(');
        expect(at, greaterThanOrEqualTo(0), reason: f);
        final call = text.substring(at, text.indexOf(');', at));
        expect(call, contains('profile:'), reason: f);
        // The generation-to-profile mapping lives in Capabilities;
        // its behaviour is pinned in test/capabilities_test.dart.
        expect(call, contains('caps.hapticProfile'), reason: f);
      }
    });
  });
}
