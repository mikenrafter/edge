// The '~x.xs' on a pattern row is the length of the plan that is SENT, not the
// runtime stored with the rule. Delivery lengthens a stored plan to its
// recorded runtime only when that is longer than its commands add up to, so a
// shorter recorded runtime (or a profile whose timing differs from the one the
// rule was saved with) must not be what is shown.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

// buzz47 is one command that the MG feels for 4 units = 500 ms.
final _buzz47 = BakedStep(effects: [47], loop: 1, delayMs: 0);

BuzzSequence _stored(List<BakedStep> steps, {int? runtime}) =>
    BuzzSequence(
      const [0],
      durationsMs: const [125],
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: steps,
      bakedRuntimeMs: runtime,
    );

// The same measured vocabulary played at another unit (a profile whose timing
// was replaced after the rule was saved).
HapticDeviceProfile _slower(int unitMs) => HapticDeviceProfile(
      id: _mg.id,
      name: _mg.name,
      unitMs: unitMs,
      probeSetId: _mg.probeSetId,
      version: _mg.version,
      phrases: _mg.phrases,
      gaps: _mg.gaps,
    );

// What delivery plans for: the felt length it allows for, read back from the
// timeout (felt + 2 s per command + 1 s).
int _sentMs(BuzzSequence s, HapticDeviceProfile p) =>
    bandSequenceTimeout(s, p).inMilliseconds -
    2000 * bandSequenceCommands(s, p) -
    1000;

void main() {
  setUp(debugClearResolveCache);

  test('a stored runtime shorter than the command is not what is shown', () {
    final s = _stored([_buzz47], runtime: 100);
    expect(scoreDurationMs(s, _mg), 500);
    expect(scoreDurationMs(s, _mg), _sentMs(s, _mg));
  });

  test('a stored runtime longer than the commands is what is sent and shown',
      () {
    final s = _stored([_buzz47], runtime: 900);
    expect(scoreDurationMs(s, _mg), 900);
    expect(scoreDurationMs(s, _mg), _sentMs(s, _mg));
  });

  test('a stored runtime equal to the commands is unchanged', () {
    final s = _stored([_buzz47], runtime: 500);
    expect(scoreDurationMs(s, _mg), 500);
  });

  test('a profile that replaced the timing: the commands as it plays them', () {
    // Saved at 125 ms per unit (500 ms); the profile now plays 4 units at 200.
    final s = _stored([_buzz47], runtime: 500);
    final p = _slower(200);
    expect(scoreDurationMs(s, p), 800);
    expect(scoreDurationMs(s, p), _sentMs(s, p));
    // And a faster profile leaves the longer recorded runtime in force.
    final fast = _slower(100);
    expect(scoreDurationMs(s, fast), 500);
    expect(scoreDurationMs(s, fast), _sentMs(s, fast));
  });

  test('no recorded runtime: sized from the profile, as the picker does', () {
    final two = [
      _buzz47,
      BakedStep(effects: [47], loop: 1, delayMs: 100),
    ];
    final s = _stored(two);
    expect(scoreDurationMs(s, _mg), bakedRuntimeMsFor(s, _mg));
    expect(scoreDurationMs(s, _mg), greaterThanOrEqualTo(500 + 100 + 500),
        reason: 'never less than the commands and delays that are written');
  });

  test('without a profile it is the time the taps take', () {
    final s = _stored([_buzz47], runtime: 100);
    expect(scoreDurationMs(s, null), s.playTime.inMilliseconds);
  });

  test('a short recorded runtime does not let a plan past the cap', () {
    // 500 ms felt, recorded as 100: the cap judges the felt length, so over a
    // 300 ms cap the stored plan is not the one sent, and the row shows what
    // is.
    final s = _stored([_buzz47], runtime: 100);
    const cap = Duration(milliseconds: 300);
    final shown = scoreDurationMs(s, _mg, maxRuntime: cap);
    final sent = bandSequenceTimeout(s, _mg, maxRuntime: cap).inMilliseconds -
        2000 * bandSequenceCommands(s, _mg, maxRuntime: cap) -
        1000;
    expect(shown, sent);
    expect(shown, isNot(500));
    expect(shown, isNot(100));
  });
}
