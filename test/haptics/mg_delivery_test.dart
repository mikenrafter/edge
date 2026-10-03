// 8AC — delivery on a WHOOP 5.0 MG band (spec G, app_state). Since 8AE.5 the
// delivery helper lives in HapticsService (haptics_service_test.dart drives it
// against a fake and a virtual band); this file keeps the seam's own tests and
// the guards on which AppState call sites hand their delivery to the service.
//
// AppState is too heavy to drive here (its engine is a concrete BleEngine and
// the gen5 check lives in a live GATT session), so the behaviour sits in a
// seam in lib/haptics/haptic_player.dart that app_state hands its band
// primitives to, and the wiring is pinned by reading app_state.dart:
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

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/band_queue.dart' show kBandBuzzPlayback;
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import '../phase8/support/dart_source.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

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

    test('the sequence\'s extended flag reaches the plan', () {
      fakeAsync((async) {
        // N4mf R1 N4mf: a 1-unit silence is only measured on the unstable
        // 100 ms gap row.
        final s = BuzzSequence([0, 625],
            durationsMs: [500, 500], extended: true);
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

    test('the extended flag changes nothing without a profile', () {
      fakeAsync((async) {
        final s = BuzzSequence([0, 875],
            durationsMs: [500, 500], extended: true);
        final rig = _Rig(async)..deliver(s, profile: null);
        expect(rig.buzzes, [500, 500]);
        expect(rig.patterns, isEmpty);
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
      bool extended = false,
    }) =>
        BuzzSequence(
          const [0, 875],
          durationsMs: const [500, 500],
          extended: extended,
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

    test('extended does not change a baked plan', () {
      late _Rig a;
      late _Rig b;
      fakeAsync((async) {
        a = _Rig(async)..deliver(rule(id: _mg.id, plan: baked), profile: _mg);
      });
      fakeAsync((async) {
        b = _Rig(async)
          ..deliver(rule(id: _mg.id, plan: baked, extended: true),
              profile: _mg);
      });
      expect(b.patterns, a.patterns);
      expect(b.patternAt, a.patternAt);
      expect(a.patternAt, [0, 800]);
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
          ..deliver(rule(notes: 'N4ff R6 N4f', id: _mg.id), profile: _mg);
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
          _mg, extended: false)!;
      final planned = Duration(
          milliseconds: plan.runtimeMs + 2000 * plan.steps.length + 1000);
      expect(bandSequenceTimeout(s, _mg),
          planned > s.transportTimeout ? planned : s.transportTimeout);
    });
  });

  // 8AE.5: the delivery helper, the queue, the ledger and the ended signal
  // moved from AppState into HapticsService (lib/haptics/haptics_service.dart).
  // What those guards pinned inside the helper is now a behaviour test in
  // haptics_service_test.dart; what stays here is which AppState call sites
  // hand their delivery to the service.
  group('app_state wiring', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();
    final code = codeOnly(src);

    test('one helper, haptics.deliver, serves all the call sites', () {
      // alertDispatcher.bandSequence and .bandSequenceDelivery
      final start = code.indexOf('late final AlertDispatcher alertDispatcher =');
      final end = code.indexOf('AlertDispatcher debugAlertDispatcher', start);
      final dispatcher = code.substring(start, end);
      for (final param in ['bandSequence:', 'bandSequenceDelivery:']) {
        final at = dispatcher.indexOf(param);
        expect(at, greaterThanOrEqualTo(0), reason: param);
        final rest = dispatcher.substring(at + param.length);
        final next = rest.indexOf(RegExp(r'\n\s+\w+:'));
        final arg = next < 0 ? rest : rest.substring(0, next);
        expect(arg, contains('haptics.deliver'), reason: param);
      }

      // previewBuzzSequence
      final preview = bodyOf(src, 'Future<bool> previewBuzzSequence(');
      expect(preview, contains('haptics.deliver('));
    });

    test('the rule-alert path (_dispatchBandAlert) uses it too (a fourth site '
        'the spec list of three misses)', () {
      final body =
          codeOnly(bodyOf(src, 'Future<AlertDeliveryOutcome> _dispatchBandAlert('));
      expect(body, isNotEmpty);
      expect(body, contains('haptics.deliver('));
      expect(body, isNot(contains('deliverBuzzSequence(')));
      expect(body, contains('haptics.sequenceTimeout('));
    });

    test('no call site still plays the per-tap sequence itself', () {
      final start = code.indexOf('late final AlertDispatcher alertDispatcher =');
      final end = code.indexOf('AlertDispatcher debugAlertDispatcher', start);
      final dispatcher = code.substring(start, end);
      expect(dispatcher, isNot(contains('playBuzzSequence(')));
      expect(dispatcher, isNot(contains('deliverBuzzSequence(')));
      final preview = bodyOf(src, 'Future<bool> previewBuzzSequence(');
      expect(preview, isNot(contains('deliverBuzzSequence(')));
    });

    test('the preview delivery\'s deadline comes from the service\'s '
        'sequenceTimeout', () {
      final preview = bodyOf(src, 'Future<bool> previewBuzzSequence(');
      expect(preview, contains('bandTimeout:'));
      expect(preview, contains('haptics.sequenceTimeout('));
      expect(preview, isNot(contains('bandTimeout: s.transportTimeout')));
    });

    test('the strap\'s events reach the service from _onLiveEvent', () {
      final live = bodyOf(src, 'void _onLiveEvent(');
      expect(live, contains('hardwareProbes.onBandEvent(e)'));
      expect(codeOnly(live), contains('haptics.onBandEvent(e)'),
          reason: '_onLiveEvent must feed the live ended event to the '
              'service (what it does with it: haptics_service_test.dart)');
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
      // The per-tap path holds the band through one buzz's playback (8AF).
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

    test('AppState builds one service, which owns the one queue and ledger; '
        'the probes count into that ledger', () {
      expect(RegExp(r'HapticsService\(').allMatches(code), hasLength(1));
      expect(code, isNot(contains('BandCommandLedger(')));
      expect(code, isNot(contains('BandHapticQueue(')));
      expect(RegExp(r'BandHapticQueue\(').allMatches(svc), hasLength(1));
      final start = code.indexOf('late final HardwareProbeRunner hardwareProbes');
      final probes =
          code.substring(start, code.indexOf('Future<bool> _probeBuzz(', start));
      expect(probes, contains('ledger: haptics.ledger'));
      expect(probes, contains('runLab: haptics.runLab'));
    });

    test('the setting reaches the service from Prefs, once', () {
      final start = code.indexOf('late final HapticsService haptics');
      final ctor = code.substring(start, code.indexOf(');', start));
      expect(ctor, contains('allowLong: () => Prefs.allowLongHaptics'));
      expect(ctor, contains('BleEngineHapticsPort(engine)'));
    });

    test('runJob is the one door to the queue', () {
      expect(RegExp(r'_queue\.run\(').allMatches(svc), hasLength(1));
      expect(code, isNot(contains('.run(\n        job')));
    });

    test('every band haptic path runs inside a queue job', () {
      // The helper for the four rhythm call sites.
      expect(code, contains('haptics.deliver('));
      // The ECG touch counter and its failure buzz.
      expect(bodyOf(src, 'Future<bool> _ecgTapBuzz('), contains('haptics.runJob('));
      expect(bodyOf(src, 'Future<bool> _ecgTapFailBuzz('),
          contains('haptics.runJob('));
      // The user-facing test buzz, pattern test and find-my-strap.
      expect(bodyOf(src, 'Future<bool> _userBuzz('), contains('haptics.runJob('));
      // The alert dispatcher's default band transport (tap ack, water and
      // medication buzzes without a saved rhythm).
      final start = code.indexOf('late final AlertDispatcher alertDispatcher =');
      final dispatcher =
          code.substring(start, code.indexOf('AlertDispatcher debugAlertDispatcher', start));
      final band = dispatcher.substring(
          dispatcher.indexOf('band:'), dispatcher.indexOf('bandSequence:'));
      expect(band, contains('haptics.runJob('));
      // The alarm and fixed pattern of _dispatchBandAlert.
      final alert = codeOnly(
          bodyOf(src, 'Future<AlertDeliveryOutcome> _dispatchBandAlert('));
      expect(alert, contains('haptics.runJob('));
    });

    test('the dispatcher gives the queue its time', () {
      final start = code.indexOf('late final AlertDispatcher alertDispatcher =');
      final dispatcher =
          code.substring(start, code.indexOf('AlertDispatcher debugAlertDispatcher', start));
      expect(dispatcher, contains('bandQueueWait: kBandQueueWait'));
      expect(dispatcher, contains('sequenceTimeout:'));
      expect(dispatcher, contains('haptics.sequenceTimeout'));
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

    test('the buzz probe counts its writes through the probe\'s own '
        'reservation, not a second record here', () {
      expect(bodyOf(src, 'Future<bool> _probeBuzz('),
          isNot(contains('haptics.ledger.record(')));
    });

    test('the notification relay is handed the queue, the delivery and its '
        'deadline', () {
      final start = code.indexOf('late final NotificationRelay notificationRelay');
      final relay =
          code.substring(start, code.indexOf('late final WaterBuzzer', start));
      expect(relay, contains('deliverSequence: haptics.deliver'));
      expect(relay, contains('runBand: haptics.runJob'));
      expect(relay, contains('sequenceTimeout:'));
    });

    // 8AD: both rows open the pattern picker, which hands the profile on to
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
        expect(call, contains('HapticDeviceProfile.forGeneration('),
            reason: f);
      }
    });
  });
}
