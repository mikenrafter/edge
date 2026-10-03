// External review 8, findings 5, 6 (the BuzzSequence half) and 9 (the data
// half): a saved baked plan still obeys the active runtime cap, stored plans
// are limited to the compiler's eight commands, and a pattern's duration is
// the baked plan's, not the compatibility taps'.
//
// Only API that exists today is used, so each test fails on behaviour before
// the fix, not on a compile error.

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/pattern_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

// 11.75 s felt: over the 10 s cap, six commands.
const String _long = 'N4ff R12 N4ff R12 N4ff R12 N4ff R12 N4ff R12 N4ff';
// A 4 s plan whose taps cannot be held (a 3 s gap), so the taps are the
// minimal 0.5 s fallback.
const String _gappy = 'N4ff R12 R12 N4ff';

HapticPlan _plan(String code, {int? maxRuntimeMs}) => compile(
  PatternTranscript.parseCode(code).entries,
  _mg,
  extended: false,
  maxRuntimeMs: maxRuntimeMs,
)!;

List<BakedStep> _baked(HapticPlan plan) => [
  for (final s in plan.steps)
    BakedStep(
      effects: s.phrase.effects,
      loop: s.phrase.loop,
      delayMs: s.delayMs,
    ),
];

/// A saved rule as the editor writes it: the taps of the notes, the notes,
/// the profile and the baked plan, through JSON like a real save.
BuzzSequence _saved(String code, {Map<String, Object?> extra = const {}}) {
  final plan = _plan(code);
  final taps = tapsFromNotes(
    PatternTranscript.parseCode(code).entries,
    unitMs: _mg.unitMs,
  );
  final json = <String, Object?>{
    'offsetsMs': taps.offsetsMs,
    'durationsMs': taps.durationsMs,
    'notes': code,
    'profileId': _mg.id,
    'profileVersion': _mg.version,
    'plan': [for (final b in _baked(plan)) b.toJson()],
    ...extra,
  };
  return BuzzSequence.fromJson(jsonDecode(jsonEncode(json)));
}

class _Band {
  final writes = <String>[];
  Future<bool> write(List<int> effects, int loop) async {
    writes.add('$effects x$loop');
    return true;
  }

  Future<bool> buzz() async => true;
  Future<bool> ended(Duration t) async => true;
}

_Band _deliver(BuzzSequence s, {required Duration? cap}) {
  final band = _Band();
  fakeAsync((async) {
    deliverBandSequence(
      s,
      profile: _mg,
      buzz: band.buzz,
      writePattern: band.write,
      waitEnded: band.ended,
      isConnected: () => true,
      maxRuntime: cap,
    );
    async.elapse(const Duration(minutes: 5));
  });
  return band;
}

void main() {
  group('finding 5: a baked plan respects the active runtime cap', () {
    test('a long plan saved with allow-long on is not played with it off', () {
      final plan = _plan(_long); // compiled with the cap lifted
      expect(plan.runtimeMs, greaterThan(10000));
      final s = _saved(_long);

      final lifted = _deliver(s, cap: null);
      expect(lifted.writes, hasLength(plan.steps.length));

      final capped = _deliver(s, cap: kMaxHapticRuntime);
      expect(capped.writes.length, lessThan(plan.steps.length),
          reason: 'the cap is back on: the long plan must not play');
    });

    test('the plan plays unchanged when the cap permits it', () {
      final s = _saved(_long);
      final band = _deliver(s, cap: null);
      expect(band.writes, [
        for (final b in _baked(_plan(_long))) '${b.effects} x${b.loop}',
      ]);
    });

    test('a plan inside the cap plays as stored with the cap on', () {
      final s = _saved('N4mf R4 N4mf');
      final band = _deliver(s, cap: kMaxHapticRuntime);
      expect(band.writes, [
        for (final b in _baked(_plan('N4mf R4 N4mf'))) '${b.effects} x${b.loop}',
      ]);
    });

    test('a stored runtime over the cap refuses the plan', () {
      // The stored step is not what the notes compile to, so what played says
      // which one the delivery used. Its stored felt runtime is 11 s.
      final s = BuzzSequence.fromJson({
        'offsetsMs': [0],
        'durationsMs': [500],
        'notes': 'N4mf',
        'profileId': _mg.id,
        'profileVersion': _mg.version,
        'plan': [
          {'effects': [14], 'loop': 1, 'delayMs': 0},
        ],
        'bakedRuntimeMs': 11000,
      });
      expect(_deliver(s, cap: null).writes, ['[14] x1']);
      final capped = _deliver(s, cap: kMaxHapticRuntime);
      expect(capped.writes, isNot(contains('[14] x1')),
          reason: 'refused: not played as the stored plan');
    });

    test('the plan runtime is written to JSON only when set', () {
      final old = _saved('N4mf R4 N4mf');
      expect((old.toJson() as Map).containsKey('bakedRuntimeMs'), isFalse);
      final withRuntime = _saved('N4mf R4 N4mf', extra: {'bakedRuntimeMs': 1375});
      expect((withRuntime.toJson() as Map)['bakedRuntimeMs'], 1375);
      expect(BuzzSequence.fromJson(withRuntime.toJson()), withRuntime);
    });

    test('old JSON without the runtime round-trips byte for byte', () {
      final raw = jsonEncode({
        'offsetsMs': [0, 625],
        'durationsMs': [500, 500],
        'notes': 'N4mf R1 N4mf',
        'profileId': _mg.id,
        'profileVersion': _mg.version,
        'plan': [
          {'effects': [47], 'loop': 1, 'delayMs': 0},
          {'effects': [14], 'loop': 1, 'delayMs': 300},
        ],
      });
      expect(jsonEncode(BuzzSequence.fromJson(jsonDecode(raw)).toJson()), raw);
    });
  });

  group('finding 6: stored plans are limited to eight commands', () {
    List<BakedStep> n(int k) => [
      for (var i = 0; i < k; i++)
        BakedStep(effects: const [47], loop: 1, delayMs: i == 0 ? 0 : 100),
    ];
    Map<String, Object?> json(int k) => {
      'offsetsMs': [0],
      'durationsMs': [500],
      'notes': 'N4ff',
      'profileId': _mg.id,
      'profileVersion': _mg.version,
      'plan': [for (final b in n(k)) b.toJson()],
    };

    test('the constructor takes eight and refuses nine', () {
      expect(
        BuzzSequence(const [0], bakedSteps: n(8)).bakedSteps,
        hasLength(8),
      );
      expect(
        () => BuzzSequence(const [0], bakedSteps: n(9)),
        throwsArgumentError,
      );
    });

    test('fromJson takes eight and refuses nine and 31', () {
      expect(BuzzSequence.fromJson(json(8)).bakedSteps, hasLength(8));
      expect(() => BuzzSequence.fromJson(json(9)), throwsFormatException);
      expect(() => BuzzSequence.fromJson(json(31)), throwsFormatException);
    });

    test('a persisted pattern with 31 steps is dropped from the store', () async {
      SharedPreferences.setMockInitialValues({
        HapticPatternStore.prefsKey: jsonEncode([
          {'id': 'big', 'name': 'Big', 'sequence': json(31)},
          {'id': 'ok', 'name': 'Fine', 'sequence': json(2)},
        ]),
      });
      final store = await HapticPatternStore.load();
      expect([for (final p in store.list) p.id], ['ok']);
    });

    test('copyWith cannot sneak an oversize plan in either', () {
      final s = BuzzSequence(const [0]);
      expect(() => s.copyWith(bakedSteps: n(9)), throwsArgumentError);
    });
  });

  group('finding 9: the duration is the baked plan\'s', () {
    // Persisted as the editor writes it (plan runtime included), a 4 s plan.
    test('a stored runtime is what patternDetail shows', () {
      final plan = _plan(_gappy);
      expect(plan.runtimeMs, 4000);
      final s = _saved(_gappy, extra: {'bakedRuntimeMs': plan.runtimeMs});
      // The taps for this rhythm are the 0.5 s fallback, not what plays.
      expect(s.playTime, const Duration(milliseconds: 500));
      expect(patternDetail(s), '2 commands · ~4.0 s');
    });

    test('no plan runtime and no profile: the count, no invented time', () {
      final s = _saved(_gappy);
      expect(patternDetail(s), isNot(contains('0.5')));
    });
  });
}
