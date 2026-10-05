// 8AF.6 section A (red first): the fastest-phrase selection on a device
// profile. The gesture built-ins (start, follow-up, confirm) are seeded from
// it, so these tests pin the picks against the measured table: when the
// vocabulary changes, the pick changes deliberately and this file says so.
//
// Contracts these tests pin that the spec leaves open:
//  - `HapticDeviceProfile.fastestSingle()` and `fastestGap()` take no argument
//    (addendum F.2 removed the extended mode; both stay STABLE-only) and
//    return the row, or null when the profile has no such row.
//  - Both are reached through `dynamic` so a missing member fails the test that
//    uses it, not the whole file.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

HapticPhrase? _single(HapticDeviceProfile p) =>
    (p as dynamic).fastestSingle() as HapticPhrase?;

HapticGap? _gap(HapticDeviceProfile p) =>
    (p as dynamic).fastestGap() as HapticGap?;

List<PatternEntry> _n(String code) => PatternTranscript.parseCode(code).entries;

HapticPhrase _ph(String id, String min, String max, {bool stable = true}) =>
    HapticPhrase(
      id: id,
      effects: const [47],
      loop: 1,
      min: _n(min),
      max: _n(max),
      stable: stable,
      sourceTests: const [1],
    );

HapticGap _g(int delay, int lo, int hi, {bool stable = true}) => HapticGap(
      delayMs: delay,
      minUnits: lo,
      maxUnits: hi,
      stable: stable,
      sourceTests: const [1],
    );

HapticDeviceProfile _profile(List<HapticPhrase> phrases, List<HapticGap> gaps) =>
    HapticDeviceProfile(
      id: 'test',
      name: 'Test',
      unitMs: 125,
      probeSetId: kWhoopMgPatternProbeSetId,
      phrases: phrases,
      gaps: gaps,
    );

int _notes(List<PatternEntry> es) => es.where((e) => e.note).length;

void main() {
  group('fastestSingle on the WHOOP MG table', () {
    test('is buzz14: effect 14, N3f to N4f', () {
      final p = _single(_mg);
      expect(p, isNotNull);
      expect(p!.id, 'buzz14');
      expect(p.effects, [14]);
      expect(p.loop, 1);
      expect(p.unitsMin, 3);
      expect(p.unitsMax, 4);
    });

    test('is the table\'s own pick: stable, one note at both ends, the '
        'smallest unitsMax (then unitsMin, then id)', () {
      final singles = [
        for (final p in _mg.phrases)
          if (p.stable && _notes(p.min) == 1 && _notes(p.max) == 1) p,
      ]..sort((a, b) {
          final c = a.unitsMax.compareTo(b.unitsMax);
          if (c != 0) return c;
          final d = a.unitsMin.compareTo(b.unitsMin);
          return d != 0 ? d : a.id.compareTo(b.id);
        });
      expect(singles, isNotEmpty);
      expect(_single(_mg)!.id, singles.first.id);
      // The literal pins the table: if this changes, re-pick on purpose.
      expect(singles.first.id, 'buzz14');
    });

    test('a phrase with two notes in either rendition is never a single',
        () {
      for (final p in _mg.phrases) {
        if (_notes(p.min) != 1 || _notes(p.max) != 1) {
          expect(_single(_mg)!.id, isNot(p.id), reason: p.id);
        }
      }
    });
  });

  group('fastestSingle on a made-up profile', () {
    test('an unstable phrase is never picked, however fast', () {
      final prof = _profile([
        _ph('quick', 'N1f', 'N1f', stable: false),
        _ph('slow', 'N3f', 'N4f'),
      ], [_g(0, 3, 4)]);
      expect(_single(prof)!.id, 'slow');
    });

    test('the smallest unitsMax wins', () {
      final prof = _profile([
        _ph('long', 'N2f', 'N6f'),
        _ph('short', 'N3f', 'N4f'),
      ], [_g(0, 3, 4)]);
      expect(_single(prof)!.id, 'short');
    });

    test('a tie on unitsMax goes to the smaller unitsMin, then the id', () {
      final byMin = _profile([
        _ph('a', 'N3f', 'N4f'),
        _ph('b', 'N2f', 'N4f'),
      ], [_g(0, 3, 4)]);
      expect(_single(byMin)!.id, 'b');
      final byId = _profile([
        _ph('zeta', 'N3f', 'N4f'),
        _ph('alpha', 'N3f', 'N4f'),
      ], [_g(0, 3, 4)]);
      expect(_single(byId)!.id, 'alpha');
    });

    test('min AND max must each be exactly one note', () {
      final prof = _profile([
        // One note when short, two when long: not a single.
        _ph('splits', 'N2f', 'N2f R1 N1f'),
        // Two notes at both ends.
        _ph('pair', 'N1f R1 N1f', 'N1f R1 N1f'),
        _ph('whole', 'N4f', 'N4f'),
      ], [_g(0, 3, 4)]);
      expect(_single(prof)!.id, 'whole');
    });
  });

  group('fastestGap', () {
    test('on the WHOOP MG table is the 0 ms row, 3 to 4 sixteenths', () {
      final g = _gap(_mg);
      expect(g, isNotNull);
      expect(g!.delayMs, 0);
      expect(g.minUnits, 3);
      expect(g.maxUnits, 4);
      expect(g.stable, isTrue);
    });

    test('is the stable row with the smallest maxUnits, then the lowest '
        'delay', () {
      final rows = [
        for (final g in _mg.gaps)
          if (g.stable) g,
      ]..sort((a, b) {
          final c = a.maxUnits.compareTo(b.maxUnits);
          return c != 0 ? c : a.delayMs.compareTo(b.delayMs);
        });
      expect(_gap(_mg)!.delayMs, rows.first.delayMs);
      expect(rows.first.delayMs, 0, reason: 'the table pin');
      expect(rows.first.maxUnits, 4, reason: 'the table pin');
    });

    test('an unstable row is never picked, however short', () {
      final prof = _profile([
        _ph('p', 'N3f', 'N4f'),
      ], [
        _g(100, 1, 2, stable: false),
        _g(300, 4, 6),
      ]);
      expect(_gap(prof)!.delayMs, 300);
    });

    test('a tie on maxUnits goes to the lowest delay', () {
      final prof = _profile([
        _ph('p', 'N3f', 'N4f'),
      ], [
        _g(300, 3, 4),
        _g(100, 3, 4),
        _g(700, 2, 4),
      ]);
      expect(_gap(prof)!.delayMs, 100);
    });
  });
}
