// Oct 4: breathing cues are haptic slots (breath.inhale|exhale|hold|done).
// What the band is written for each, over the real engine path (the fake
// link): four different built-in defaults on a gen5, the wearer's assigned
// pattern in place of a default, a 4.0 keeping its per-tap buzzes unless the
// wearer assigned the slot, and the band queue's spacing (a phase cue that
// would start while the band is still playing the last one is skipped, not
// stacked behind it; the session-complete cue is queued, never skipped).
// Also the controller's own routing, with the band stubbed.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/breathing_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show BandProfile;

import 'support/app_state_live_harness.dart';
import 'support/app_state_workout_harness.dart';

const _db = 'split8aj_seam4_breath_cues.db';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

String _body(G6Write w) => '${w.opcode}:${w.body}';

/// Save [code] as the wearer's own pattern and put it on cue [slot]. Asking
/// again for the same name reuses the stored pattern.
Future<void> _assign(String slot, String name, String code) async {
  final store = await SettingsRepository.instance.patterns();
  final p = store.list.where((x) => x.name == name).firstOrNull ??
      store.add(
        name,
        tapsFromNotes(PatternTranscript.parseCode(code).entries,
                unitMs: _mg.unitMs)
            .copyWith(
                notes: code, profileId: _mg.id, profileVersion: _mg.version),
      );
  await store.save();
  Prefs.setString(Prefs.hapticsCueAssign, encodeCueAssignments({slot: p.id}));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await Prefs.ensureLoaded();
    Prefs.setString(Prefs.hapticsCueAssign, '');
  });
  tearDown(() async {
    await settleMs(300);
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  // The writes one cue makes, on a fresh rig, once the band has had time to
  // play it.
  Future<List<String>> cue(
    void Function(AppState) play, {
    BandProfile band = BandProfile.gen5,
    int expect_ = 1,
    Future<void> Function()? before,
  }) async {
    final rig = G6Rig(band: band);
    if (before != null) await before();
    play(rig.app);
    await until(() => rig.writes.length >= expect_,
        within: const Duration(seconds: 6));
    await settleMs(100);
    final out = [for (final w in rig.writes) _body(w)];
    await finish(rig.app);
    BleEngine.resetBandClaimForTest();
    return out;
  }

  group('gen5: the defaults', () {
    test('inhale, exhale, hold and done write four different single commands',
        () async {
      final out = <String, String>{};
      final plays = <String, void Function(AppState)>{
        kBreathInhaleKey: (a) => a.buzzBreathPhase(BreathPhaseKind.inhale),
        kBreathExhaleKey: (a) => a.buzzBreathPhase(BreathPhaseKind.exhale),
        kBreathHoldKey: (a) => a.buzzBreathPhase(BreathPhaseKind.holdIn),
        kBreathDoneKey: (a) => a.buzzSessionComplete(),
      };
      for (final e in plays.entries) {
        final w = await cue(e.value);
        expect(w, hasLength(1), reason: e.key);
        out[e.key] = w.single;
      }
      expect(out.values.toSet(), hasLength(4), reason: '$out');
    });

    test('the interval kinds borrow the cues: work plays inhale, rest plays '
        'exhale, the two holds are one', () async {
      final inhale =
          await cue((a) => a.buzzBreathPhase(BreathPhaseKind.inhale));
      final work = await cue((a) => a.buzzBreathPhase(BreathPhaseKind.work));
      final exhale =
          await cue((a) => a.buzzBreathPhase(BreathPhaseKind.exhale));
      final rest = await cue((a) => a.buzzBreathPhase(BreathPhaseKind.rest));
      final holdIn = await cue((a) => a.buzzBreathPhase(BreathPhaseKind.holdIn));
      final holdOut =
          await cue((a) => a.buzzBreathPhase(BreathPhaseKind.holdOut));
      expect(work, inhale);
      expect(rest, exhale);
      expect(holdOut, holdIn);
    });
  });

  group('gen5: an assigned pattern', () {
    test('replaces that phase\'s default and leaves the others alone',
        () async {
      final defInhale =
          await cue((a) => a.buzzBreathPhase(BreathPhaseKind.inhale));
      final defExhale =
          await cue((a) => a.buzzBreathPhase(BreathPhaseKind.exhale));
      final assigned = await cue(
        (a) => a.buzzBreathPhase(BreathPhaseKind.inhale),
        before: () => _assign(kBreathInhaleKey, 'Slow in', 'N8ff'),
      );
      expect(assigned, hasLength(1));
      expect(assigned, isNot(defInhale), reason: 'the saved pattern plays');
      final exhale = await cue(
        (a) => a.buzzBreathPhase(BreathPhaseKind.exhale),
        before: () => _assign(kBreathInhaleKey, 'Slow in', 'N8ff'),
      );
      expect(exhale, defExhale, reason: 'exhale was not assigned');
    });

    test('is read when the cue plays: put back to the default, the default '
        'plays again with no restart', () async {
      final def = await cue((a) => a.buzzBreathPhase(BreathPhaseKind.holdIn));
      await _assign(kBreathHoldKey, 'Long hold', 'N8ff');
      final rig = G6Rig();
      addTearDown(() async {
        await finish(rig.app);
        BleEngine.resetBandClaimForTest();
      });
      rig.app.buzzBreathPhase(BreathPhaseKind.holdIn);
      await until(() => rig.writes.isNotEmpty);
      expect(_body(rig.writes.single), isNot(def.single));
      await rig.app.haptics.whenIdle();
      Prefs.setString(Prefs.hapticsCueAssign, '');
      rig.writes.clear();
      rig.app.buzzBreathPhase(BreathPhaseKind.holdOut);
      await until(() => rig.writes.isNotEmpty);
      expect(_body(rig.writes.single), def.single);
    });

    test('an assignment naming a pattern that is gone plays the built-in',
        () async {
      final def = await cue((a) => a.buzzSessionComplete());
      Prefs.setString(Prefs.hapticsCueAssign,
          encodeCueAssignments({kBreathDoneKey: 'no-such-pattern'}));
      final w = await cue((a) => a.buzzSessionComplete());
      expect(w, def);
    });
  });

  group('gen4', () {
    test('keeps its distinct per-tap buzzes (inhale, exhale, hold, done)',
        () async {
      final bodies = <String>{};
      for (final play in <void Function(AppState)>[
        (a) => a.buzzBreathPhase(BreathPhaseKind.inhale),
        (a) => a.buzzBreathPhase(BreathPhaseKind.exhale),
        (a) => a.buzzBreathPhase(BreathPhaseKind.holdIn),
        (a) => a.buzzSessionComplete(),
      ]) {
        final w = await cue(play, band: BandProfile.gen4);
        expect(w, hasLength(1));
        bodies.add(w.single);
      }
      expect(bodies, hasLength(4));
    });

    test('a slot the wearer assigned plays that pattern\'s taps instead; '
        'the others keep their buzz', () async {
      final plain = await cue((a) => a.buzzBreathPhase(BreathPhaseKind.inhale),
          band: BandProfile.gen4);
      final plainExhale = await cue(
          (a) => a.buzzBreathPhase(BreathPhaseKind.exhale),
          band: BandProfile.gen4);
      final w = await cue(
        (a) => a.buzzBreathPhase(BreathPhaseKind.inhale),
        band: BandProfile.gen4,
        expect_: 3,
        before: () => _assign(kBreathInhaleKey, 'Triple', 'N4* R4 N4* R4 N4*'),
      );
      expect(w.length, 3, reason: 'one buzz per tap of the assigned pattern');
      expect(plain, hasLength(1));
      final exhale = await cue(
        (a) => a.buzzBreathPhase(BreathPhaseKind.exhale),
        band: BandProfile.gen4,
        before: () => _assign(kBreathInhaleKey, 'Triple', 'N4* R4 N4* R4 N4*'),
      );
      expect(exhale, plainExhale);
    });
  });

  group('the band queue\'s spacing', () {
    test('a phase cue is rejected immediately when the command budget is full',
        () async {
      final rig = G6Rig();
      addTearDown(() async {
        await finish(rig.app);
        BleEngine.resetBandClaimForTest();
      });
      rig.app.haptics.ledger.record(30, DateTime.now());
      rig.app.buzzBreathPhase(BreathPhaseKind.inhale);
      await settleMs(300);
      expect(rig.writes, isEmpty);
      expect(rig.app.haptics.pending, 0,
          reason: 'a phase cue must not wait for budget to free');
    });

    test('a phase cue is rejected while the device lab is open', () async {
      final rig = G6Rig();
      addTearDown(() async {
        rig.app.haptics.endLab();
        await finish(rig.app);
        BleEngine.resetBandClaimForTest();
      });
      rig.app.haptics.beginLab();
      rig.app.buzzBreathPhase(BreathPhaseKind.exhale);
      await settleMs(300);
      expect(rig.writes, isEmpty);
      expect(rig.app.haptics.pending, 0,
          reason: 'a phase cue must not be held behind the lab');
    });

    test('a phase cue that arrives while the last one still plays is '
        'skipped, not stacked behind it', () async {
      final rig = G6Rig();
      addTearDown(() async {
        await finish(rig.app);
        BleEngine.resetBandClaimForTest();
      });
      rig.app.buzzBreathPhase(BreathPhaseKind.inhale);
      await until(() => rig.writes.isNotEmpty);
      expect(rig.writes, hasLength(1));
      // The fake band never reports the end, so the first cue holds the band
      // for its bounded playback: a phase shorter than its cue is this case.
      expect(rig.app.haptics.pending, greaterThan(0));
      rig.app.buzzBreathPhase(BreathPhaseKind.exhale);
      rig.app.buzzBreathPhase(BreathPhaseKind.holdIn);
      await rig.app.haptics.whenIdle();
      await settleMs(300);
      expect(rig.writes, hasLength(1),
          reason: 'neither skipped cue was played late');
      expect(rig.app.haptics.pending, 0, reason: 'and none is waiting');
      // Once the band is free the next phase cue plays.
      rig.app.buzzBreathPhase(BreathPhaseKind.exhale);
      await until(() => rig.writes.length >= 2);
      expect(rig.writes, hasLength(2));
    });

    test('the session-complete cue is queued behind a playing phase cue and '
        'written only after it finished (pinned: the queue serialises, never '
        'overlaps)', () async {
      final rig = G6Rig();
      addTearDown(() async {
        await finish(rig.app);
        BleEngine.resetBandClaimForTest();
      });
      rig.app.buzzBreathPhase(BreathPhaseKind.exhale);
      await until(() => rig.writes.isNotEmpty);
      rig.app.buzzSessionComplete();
      await settleMs(200);
      expect(rig.writes, hasLength(1), reason: 'still waiting its turn');
      await until(() => rig.writes.length >= 2,
          within: const Duration(seconds: 8));
      expect(rig.writes, hasLength(2));
      expect(_body(rig.writes.first), isNot(_body(rig.writes.last)));
    });

    test('an unassigned gen4 phase cue is also rejected while the band is busy',
        () async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(() async {
        await finish(rig.app);
        BleEngine.resetBandClaimForTest();
      });
      rig.app.buzzBreathPhase(BreathPhaseKind.inhale);
      await until(() => rig.writes.isNotEmpty);
      rig.app.buzzBreathPhase(BreathPhaseKind.exhale);
      await rig.app.haptics.whenIdle();
      await settleMs(300);
      expect(rig.writes, hasLength(1),
          reason: 'the fallback per-tap path cannot queue a late phase cue');
    });
  });

  group('BreathingController routing', () {
    final cues = <(String, bool)>[];
    final legacy = <(String, int?)>[];
    BreathingController build(
      Future<bool> Function(String, {required bool skipIfBusy})? playCue, {
      bool connected = true,
    }) =>
        BreathingController(
          isConnected: () => connected,
          reconcileLiveStreams: () async {},
          nudgeLive: () {},
          repo: () => null,
          dispatchBandAlert: (rule, {pattern}) async {
            legacy.add((rule, pattern));
            return const AlertDeliveryOutcome([], 'test');
          },
          notify: () {},
          playCue: playCue,
        );
    setUp(() {
      cues.clear();
      legacy.clear();
    });

    test('each kind asks for its slot: phases skip when the band is busy, '
        'done does not', () async {
      final c = build((slot, {required skipIfBusy}) async {
        cues.add((slot, skipIfBusy));
        return true;
      });
      for (final k in BreathPhaseKind.values) {
        c.buzzBreathPhase(k);
      }
      c.buzzSessionComplete();
      await settleMs(10);
      expect(cues, [
        (kBreathInhaleKey, true), // inhale
        (kBreathHoldKey, true), // holdIn
        (kBreathExhaleKey, true), // exhale
        (kBreathHoldKey, true), // holdOut
        (kBreathInhaleKey, true), // work
        (kBreathExhaleKey, true), // rest
        (kBreathDoneKey, false),
      ]);
      expect(legacy, isEmpty, reason: 'the slot played them');
    });

    test('a slot that declines (a 4.0 with nothing assigned) falls back to '
        'the per-tap pattern index, as before', () async {
      final c = build((slot, {required skipIfBusy}) async => false);
      c.buzzBreathPhase(BreathPhaseKind.inhale);
      c.buzzBreathPhase(BreathPhaseKind.exhale);
      c.buzzBreathPhase(BreathPhaseKind.holdOut);
      c.buzzSessionComplete();
      await settleMs(10);
      expect(legacy, [
        ('breath', 1),
        ('breath', 0),
        ('breath', 2),
        ('breath', 4),
      ]);
    });

    test('a slot that throws falls back too, and nothing escapes', () async {
      final c = build((slot, {required skipIfBusy}) async =>
          throw StateError('settings unreadable'));
      c.buzzBreathPhase(BreathPhaseKind.inhale);
      await settleMs(10);
      expect(legacy, [('breath', 1)]);
    });

    test('disconnected: neither path is asked', () async {
      final c = build((slot, {required skipIfBusy}) async {
        cues.add((slot, skipIfBusy));
        return true;
      }, connected: false);
      c.buzzBreathPhase(BreathPhaseKind.inhale);
      c.buzzSessionComplete();
      await settleMs(10);
      expect(cues, isEmpty);
      expect(legacy, isEmpty);
    });
  });
}
