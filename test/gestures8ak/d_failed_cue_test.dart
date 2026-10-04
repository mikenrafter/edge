// 8AK D (red): the failure buzz becomes a named, assignable cue, "Gesture
// failed".
//
// USER: "the failure buzz becomes a named, assignable cue 'Gesture failed' in
// Haptics > Where patterns are used > Gestures, played through GestureCues like
// the other cues; its built-in default = today's failure buzz shape, so nothing
// changes until the user assigns one."
//
// ASSUMED API:
//   * System key `gesture.failed` (constant `kGestureFailedKey` in
//     lib/haptics/builtin_patterns.dart; these tests use the literal).
//   * `builtInDefault('gesture.failed')`: name "Gesture failed", the sequence of
//     TODAY'S failure buzz: `engine.buzzBand(holdMs: 600)` on a Maverick band =
//     the one command `[47, 152]` looped twice, i.e. the library phrase
//     `pairx2` (notes `N2mf R2 N2mf R2 N2mf`: three medium pulses). It is
//     listed after the confirm cue in `builtInKeys()` and is seeded into the
//     pattern store like the other cues (HapticPatternStore.decodeSeeded).
//   * `kHapticSlotSections` 'gestures' gets a fourth slot,
//     `HapticSlot('gesture.failed', 'Gesture failed')`; `isGestureCueSlot` and
//     `decodeCueAssignments` accept it, `resolveCuePatterns` resolves it (the
//     assigned pattern wins, else the stored built-in, else the default).
//   * `GestureCues.failed()` -> Future<BuzzDelivery>, one queue job like the
//     other cues; a band with no haptic profile (a 4.0) plays one plain pulse.
//   * AppState `_ecgTapFailBuzz` goes through `gestureCues.failed` (via
//     `_gestureCue`, so the wearer's assignment is read and the dispatcher's
//     claim/deadline steps apply), not `engine.buzzBand(holdMs: 600)`.
//
// Failure mode today: no such key, slot or method; the failure buzz is a
// fixed engine call.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import '../fix8ai/support/g45_support.dart';
import '../phase8/support/dart_source.dart';
import '../support/virtual_mg.dart';

const String _key = 'gesture.failed';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

(VirtualMgBand, HapticsService) _rig({String generation = 'gen5'}) {
  final band = VirtualMgBand(generation: generation);
  final svc = HapticsService(port: band, allowLong: () => false);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

List<String> _cmds(VirtualMgBand b) =>
    [for (final w in b.writes) '${w.effects} x${w.loop}'];

Future<BuzzDelivery> _failed(GestureCues c) =>
    (c as dynamic).failed() as Future<BuzzDelivery>;

void main() {
  group('the built-in default is today\'s failure buzz', () {
    test('"Gesture failed": one command, [47, 152] looped twice, three medium '
        'pulses', () {
      final spec = builtInDefault(_key);
      expect(spec, isNotNull);
      expect(spec!.name, 'Gesture failed');
      expect(spec.key, _key);
      final steps = spec.sequence.bakedSteps!;
      expect(steps, hasLength(1));
      expect(steps.single.effects, [47, 152]);
      expect(steps.single.loop, 2);
      expect(steps.single.delayMs, 0);
      expect(spec.sequence.notes, 'N2mf R2 N2mf R2 N2mf');
    });

    test('it is the shape the engine plays today for a hold of 600 ms: the '
        'virtual band\'s buzzBand(holdMs: 600) and the new cue write the '
        'same command', () {
      fakeAsync((async) {
        final (old, _) = _rig();
        old.buzzBand(holdMs: 600);
        final (band, svc) = _rig();
        _failed(GestureCues(haptics: svc));
        async.elapse(const Duration(seconds: 20));
        expect(_cmds(band), _cmds(old));
        expect(_cmds(band), ['[47, 152] x2']);
      });
    });

    test('builtInKeys lists it right after the three cues', () {
      expect(builtInKeys().take(4), [
        'gesture.start',
        'gesture.followUp',
        'gesture.confirm',
        _key,
      ]);
    });

    test('the seeded pattern store holds it as a system pattern', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final p = store.bySystemKey(_key);
      expect(p, isNotNull);
      expect(p!.system, isTrue);
      expect(p.name, 'Gesture failed');
    });
  });

  group('played through GestureCues', () {
    test('failed() plays the default as ONE job on a Maverick band', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        BuzzDelivery? done;
        _failed(GestureCues(haptics: svc)).then((v) => done = v);
        async.elapse(const Duration(seconds: 20));
        expect(done, BuzzDelivery.complete);
        expect(_cmds(band), ['[47, 152] x2']);
      });
    });

    test('an assigned pattern is what plays', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final mine = BuzzSequence(
          const [0],
          durationsMs: const [500],
          profileId: _mg.id,
          profileVersion: _mg.version,
          bakedSteps: [BakedStep(effects: const [14], loop: 1, delayMs: 0)],
        );
        final cues = GestureCues(
          haptics: svc,
          patternFor: (k) => k == _key ? mine : null,
        );
        _failed(cues);
        async.elapse(const Duration(seconds: 20));
        expect(_cmds(band), ['[14] x1']);
      });
    });

    test('it is spaced from the cue before it by the queue, never merged', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(haptics: svc);
        cues.followUp();
        _failed(cues);
        async.elapse(const Duration(seconds: 30));
        expect(_cmds(band), ['[14] x1', '[47, 152] x2']);
        expect(band.played, hasLength(2));
      });
    });

    test('a band with no haptic profile (a 4.0) plays one plain pulse', () {
      fakeAsync((async) {
        final (band, svc) = _rig(generation: 'gen4');
        _failed(GestureCues(haptics: svc));
        async.elapse(const Duration(seconds: 20));
        expect(band.writes, hasLength(1));
      });
    });
  });

  group('the slot', () {
    test('the Gestures section lists four slots, "Gesture failed" last', () {
      final gestures =
          kHapticSlotSections.firstWhere((s) => s.id == 'gestures');
      expect([for (final s in gestures.slots) s.key], [
        'gesture.start',
        'gesture.followUp',
        'gesture.confirm',
        _key,
      ]);
      expect(gestures.slots.last.label, 'Gesture failed');
    });

    test('it is a gesture cue slot: assignments to it are kept', () {
      expect(isGestureCueSlot(_key), isTrue);
      expect(decodeCueAssignments('{"$_key":"p1","alert.water":"p2"}'),
          {_key: 'p1'});
    });

    test('the cue patterns resolve it: the default, then an assigned pattern',
        () {
      final store = HapticPatternStore.decodeSeeded(null);
      expect(resolveCuePatterns(store, const {}).containsKey(_key), isTrue);
      final mine = store.add(
        'Mine',
        BuzzSequence(
          const [0],
          durationsMs: const [500],
          profileId: _mg.id,
          profileVersion: _mg.version,
          notes: 'N4mf',
          bakedSteps: [BakedStep(effects: const [14], loop: 1, delayMs: 0)],
        ),
      );
      final resolved = resolveCuePatterns(store, {_key: mine.id});
      expect(resolved[_key]!.bakedSteps!.single.effects, [14]);
      // The assigned pattern changes this slot only.
      expect(resolved['gesture.confirm']!.bakedSteps!.single.effects,
          isNot([14]));
    });

    testWidgets('Haptics > Where patterns are used > Gestures shows the row '
        'and can assign a pattern to it', (t) async {
      final c = HubCalls();
      await pumpHub(t, c,
          patterns: [userPattern('a', 'Mine')], profile: kMg);
      final row = find.byKey(const ValueKey('haptic-slot:$_key'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Gesture failed')),
          findsOneWidget);
      await t.tap(row);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pattern-picker-row:a')));
      await t.pumpAndSettle();
      expect(c.assigned, [(_key, 'a')]);
    });
  });

  group('the wiring', () {
    test('the gesture controller plays the failure through cues.failed, not a '
        'fixed engine buzz', () {
      final src = File('lib/state/gesture_controller.dart').readAsStringSync();
      final fn = codeOnly(bodyOf(src, 'Future<bool> _ecgTapFailBuzz'));
      expect(fn, contains('cues.failed'));
      expect(fn, isNot(contains('buzzBand')));
      expect(fn, contains('_gestureCue'),
          reason: 'one path for every gesture cue: the dispatcher claim, the '
              'wearer\'s assignment read, the lab work wrapper');
    });
  });
}
