// 8AI.3 (red): the cue the wearer ASSIGNED is the cue that plays.
//
// User report: the confirm cue was assigned a "__" pattern and the band played
// a different one. Two causes:
//   1. A counted gesture never played the confirm cue at all: its closing buzz
//      was response(1), the START cue. (The session tests pin the new
//      sequence; this file pins what each cue key plays.)
//   2. The step that turns "which pattern is on which cue" into the sequences
//      GestureCues plays lived inline in AppState._loadGestureCues, where no
//      test reached it. It is now `resolveCuePatterns` (haptic_slots.dart),
//      and everything below runs through it.
//
// ASSUMED API (lib/haptics/haptic_slots.dart):
//   Map<String, BuzzSequence> resolveCuePatterns(
//       HapticPatternStore store, Map<String, String> assignments)
// The assigned pattern's sequence for each gesture cue key, else the cue's
// own built-in in the store (as customised), else absent.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import '../phase8/support/dart_source.dart';
import '../support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// A pattern as the editor stores it: its notes and the taps they make.
BuzzSequence _fromNotes(String code) => tapsFromNotes(
      PatternTranscript.parseCode(code).entries,
      unitMs: _mg.unitMs,
    ).copyWith(notes: code, profileId: _mg.id, profileVersion: _mg.version);

(VirtualMgBand, HapticsService) _rig() {
  final band = VirtualMgBand();
  final svc = HapticsService(port: band, allowLong: () => false);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

/// What the band was asked to play, as "effects xloop".
List<String> _cmds(VirtualMgBand b) =>
    [for (final w in b.writes) '${w.effects} x${w.loop}'];

/// The commands [s] compiles to on the MG.
List<String> _compiled(BuzzSequence s) => [
      for (final st in bandStepsFor(s, _mg, maxRuntime: null)!)
        '${st.effects} x${st.loop}',
    ];

/// Plays one cue of [cues] on a fresh band and returns the commands written.
List<String> _play(
  Map<String, BuzzSequence> cues,
  Future<void> Function(GestureCues) play,
) {
  late List<String> out;
  fakeAsync((async) {
    final (band, svc) = _rig();
    play(GestureCues(haptics: svc, patternFor: (k) => cues[k]));
    async.elapse(const Duration(seconds: 60));
    out = _cmds(band);
  });
  return out;
}

void main() {
  group('the cue keys', () {
    test('the Gestures slots are exactly the four cue keys GestureCues reads',
        () {
      final gestures =
          kHapticSlotSections.firstWhere((s) => s.id == 'gestures');
      // 8AK added "Gesture failed" as the fourth cue.
      expect([for (final s in gestures.slots) s.key], [
        kGestureStartKey,
        kGestureFollowUpKey,
        kGestureConfirmKey,
        kGestureFailedKey,
      ]);
    });
  });

  group('assigning a pattern to a cue', () {
    late HapticPatternStore store;
    late SavedHapticPattern slow, nudge, wave;

    setUp(() {
      store = HapticPatternStore.decodeSeeded(null);
      slow = store.add('Slow pair', _fromNotes('N4* R2 N4*'));
      nudge = store.add('Nudge', _fromNotes('N1*'));
      wave = store.add('Wave', _fromNotes('N2* R1 N2* R1 N2*'));
    });

    test('the confirm cue plays the pattern assigned to confirm, compiled '
        'for the band', () {
      final cues = resolveCuePatterns(store, {kGestureConfirmKey: slow.id});
      final played = _play(cues, (c) => c.confirm());
      expect(played, _compiled(slow.sequence));
      expect(played, isNot(_compiled(builtInDefault(kGestureConfirmKey)!.sequence)),
          reason: 'not the built-in confirm');
    });

    test('the start cue plays the pattern assigned to start', () {
      final cues = resolveCuePatterns(store, {kGestureStartKey: wave.id});
      expect(_play(cues, (c) => c.start()), _compiled(wave.sequence));
    });

    test('the follow-up cue plays the pattern assigned to follow-up', () {
      final cues = resolveCuePatterns(store, {kGestureFollowUpKey: nudge.id});
      expect(_play(cues, (c) => c.followUp()), _compiled(nudge.sequence));
    });

    test('all three assigned: each cue plays its own, none another\'s', () {
      final cues = resolveCuePatterns(store, {
        kGestureStartKey: wave.id,
        kGestureFollowUpKey: nudge.id,
        kGestureConfirmKey: slow.id,
      });
      final played = _play(cues, (c) async {
        c.start();
        c.followUp();
        c.followUp();
        c.confirm();
      });
      expect(played, [
        ..._compiled(wave.sequence),
        ..._compiled(nudge.sequence),
        ..._compiled(nudge.sequence),
        ..._compiled(slow.sequence),
      ]);
    });

    test('what the Haptics screen stores (JSON) is what is resolved', () {
      final stored = encodeCueAssignments({kGestureConfirmKey: slow.id});
      final cues = resolveCuePatterns(store, decodeCueAssignments(stored));
      expect(_play(cues, (c) => c.confirm()), _compiled(slow.sequence));
    });

    test('an assignment whose pattern was deleted falls back to the cue\'s '
        'own built-in', () {
      final cues = resolveCuePatterns(store, {kGestureConfirmKey: 'gone'});
      expect(_play(cues, (c) => c.confirm()),
          _compiled(builtInDefault(kGestureConfirmKey)!.sequence));
    });

    test('with nothing assigned the built-in as customised in the store '
        'plays', () {
      final own = store.bySystemKey(kGestureConfirmKey)!;
      store.replace(own.id, _fromNotes('N1* R1 N1*'));
      final cues = resolveCuePatterns(store, const {});
      expect(_play(cues, (c) => c.confirm()),
          _compiled(store.bySystemKey(kGestureConfirmKey)!.sequence));
    });

    test('an assignment for a key that is not a gesture cue is ignored', () {
      final cues = resolveCuePatterns(store, {'alert.water': slow.id});
      expect(cues.keys.toSet(), {
        kGestureStartKey,
        kGestureFollowUpKey,
        kGestureConfirmKey,
        kGestureFailedKey,
      });
      expect(cues[kGestureConfirmKey]!.patternId,
          systemPatternId(kGestureConfirmKey));
    });
  });

  group('wiring (source guards)', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();

    test('AppState reads the cues through resolveCuePatterns', () {
      final body = codeOnly(bodyOf(src, 'Future<void> _loadGestureCues()'));
      expect(body, contains('resolveCuePatterns('));
    });

    test('the confirm cue is loaded before it plays on every path', () {
      final code = codeOnly(src);
      // The ack path and the counted path both read the stored cues first.
      expect(code, contains('await _loadGestureCues();'));
      final confirmWire = RegExp(r'confirmBuzz:\s*_ecgTapConfirmBuzz');
      expect(confirmWire.hasMatch(code), isTrue,
          reason: 'the touch counter\'s final cue is the confirm cue');
    });
  });
}
