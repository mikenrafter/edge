// What a band's haptic commands feel like. A device profile is the
// vocabulary measured by the pattern probe: each command the band can be sent
// (a phrase) with the shortest and longest rendition heard as notes and rests
// on a 16th grid, and the silence felt between two commands for each write
// delay (a gap). Everything here is measured, not derived; the numbers come
// from a transcribed probe log (see docs/hardware/logs). Pure Dart: no
// Flutter, no BLE.

import '../gestures/hardware_probes.dart';
import '../gestures/pattern_transcript.dart';

// The stable probe input set lives with the probe; re-exported here so a
// profile and the set it was measured with come from one import.
export '../gestures/hardware_probes.dart'
    show kWhoopMgPatternProbeSet, kWhoopMgPatternProbeSetId;

/// One band command and how it is felt. [min] and [max] are the shortest and
/// longest renditions heard (equal when only one was). Not [stable] means the
/// band's timing for it varies unexpectedly.
class HapticPhrase {
  HapticPhrase({
    required this.id,
    required List<int> effects,
    required this.loop,
    required List<PatternEntry> min,
    required List<PatternEntry> max,
    this.stable = true,
    required List<int> sourceTests,
  })  : effects = List.unmodifiable(effects),
        min = List.unmodifiable(min),
        max = List.unmodifiable(max),
        sourceTests = List.unmodifiable(sourceTests);

  final String id;

  /// The waveform slots written, and how often the band loops them.
  final List<int> effects;
  final int loop;
  final List<PatternEntry> min;
  final List<PatternEntry> max;
  final bool stable;

  /// Probe test numbers (1-based) this row was read from.
  final List<int> sourceTests;

  static int _units(List<PatternEntry> es) =>
      es.fold(0, (sum, e) => sum + e.length);

  /// Total sixteenths of the shortest and the longest rendition.
  int get unitsMin => _units(min);
  int get unitsMax => _units(max);
}

/// The rest felt between two commands when the second is written [delayMs]
/// after the band's "ended" event: [minUnits] to [maxUnits] sixteenths.
class HapticGap {
  HapticGap({
    required this.delayMs,
    required this.minUnits,
    required this.maxUnits,
    this.stable = true,
    required List<int> sourceTests,
  }) : sourceTests = List.unmodifiable(sourceTests);

  final int delayMs;
  final int minUnits;
  final int maxUnits;
  final bool stable;
  final List<int> sourceTests;
}

/// One device's measured haptic vocabulary.
class HapticDeviceProfile {
  HapticDeviceProfile({
    required this.id,
    required this.name,
    required this.unitMs,
    required this.probeSetId,
    this.version = 1,
    required List<HapticPhrase> phrases,
    required List<HapticGap> gaps,
  })  : phrases = List.unmodifiable(phrases),
        gaps = List.unmodifiable(gaps);

  final String id;
  final String name;

  /// Milliseconds per sixteenth the transcription was made at.
  final int unitMs;

  /// The probe input set the numbers were measured with.
  final String probeSetId;

  /// Bumped when the measured vocabulary changes. A saved rule records the
  /// version it was compiled against.
  final int version;
  final List<HapticPhrase> phrases;
  final List<HapticGap> gaps;

  static int _noteCount(List<PatternEntry> es) => es.where((e) => e.note).length;

  /// The quickest single command: the stable phrase whose shortest and longest
  /// renditions are each exactly one note, with the smallest [HapticPhrase
  /// .unitsMax] (ties: the smaller unitsMin, then the id). Null when there is
  /// none. Unstable phrases are never picked.
  HapticPhrase? fastestSingle() {
    HapticPhrase? best;
    for (final p in phrases) {
      if (!p.stable || _noteCount(p.min) != 1 || _noteCount(p.max) != 1) {
        continue;
      }
      if (best == null) {
        best = p;
        continue;
      }
      final c = p.unitsMax != best.unitsMax
          ? p.unitsMax.compareTo(best.unitsMax)
          : p.unitsMin != best.unitsMin
              ? p.unitsMin.compareTo(best.unitsMin)
              : p.id.compareTo(best.id);
      if (c < 0) best = p;
    }
    return best;
  }

  /// The quickest wait between two commands: the stable gap row with the
  /// smallest [HapticGap.maxUnits] (ties: the lowest delay). Null when there
  /// is none.
  HapticGap? fastestGap() {
    HapticGap? best;
    for (final g in gaps) {
      if (!g.stable) continue;
      if (best == null ||
          g.maxUnits < best.maxUnits ||
          (g.maxUnits == best.maxUnits && g.delayMs < best.delayMs)) {
        best = g;
      }
    }
    return best;
  }

  /// The least the band needs between the end of one vibration and the write
  /// of the next: the delay of [fastestGap] (0 when none is stable). The one
  /// source for every reader that chains or queues vibrations (gesture cues,
  /// wake plans, the band queue), so none of them repeats the number.
  int get minVibrationGapMs => fastestGap()?.delayMs ?? 0;

  static List<PatternEntry> _notes(String code) =>
      PatternTranscript.parseCode(code).entries;

  static HapticPhrase _phrase(
    String id,
    List<int> effects,
    int loop,
    String min,
    String? max,
    List<int> tests, {
    bool stable = true,
  }) =>
      HapticPhrase(
        id: id,
        effects: effects,
        loop: loop,
        min: _notes(min),
        max: _notes(max ?? min),
        stable: stable,
        sourceTests: tests,
      );

  /// The WHOOP 5.0 MG, from the L6 pattern probe (fixed tempo, one sixteenth
  /// 125 ms). Dynamics are as heard, except a single effect 14 is f ("14 is F,
  /// while 47 is FF"). A nearby command can spike the amplitude, hence the
  /// arcs from mf up to ff and back to mf.
  static final HapticDeviceProfile whoopMg = HapticDeviceProfile(
    id: 'whoop-5.0-mg',
    name: 'WHOOP 5.0 MG',
    unitMs: 125,
    probeSetId: kWhoopMgPatternProbeSetId,
    version: 1,
    phrases: [
      _phrase('buzz47', [47], 1, 'N4ff', null, [2, 6, 18, 22, 34, 36, 38, 40]),
      _phrase('buzz14', [14], 1, 'N3f', 'N4f', [3, 7, 19, 23, 33, 35, 37, 39]),
      _phrase('click1', [1], 1, 'N1mp N1mp', null, [4, 8, 20]),
      _phrase('pair', [47, 152], 1, 'N2mf R2 N2mf', 'N3mf R1 N3mf',
          [1, 5, 17, 21]),
      _phrase('buzz47x2', [47], 2, 'N6ff', null, [10]),
      _phrase('buzz47x3', [47], 3, 'N8ff', null, [26]),
      _phrase('buzz14x2', [14], 2, 'N6ff', null, [11]),
      _phrase('buzz14x3', [14], 3, 'N8ff', null, [27]),
      _phrase('click1x2', [1], 2, 'N1mf N1mf N1mf', null, [12]),
      _phrase('click1x3', [1], 3, 'N1mf N1mf N1mf', null, [28]),
      _phrase('pairx2', [47, 152], 2, 'N2mf R2 N2mf R2 N2mf', null, [9]),
      _phrase('pairx3', [47, 152], 3, 'N3mf R1 N3mf R1 N3mf R1 N3mf', null,
          [25]),
      _phrase('pair2', [47, 152, 47, 152], 1, 'N3ff R1 N3ff R1 N3ff R1 N3ff',
          null, [13]),
      _phrase('pair3', [47, 152, 47, 152, 47, 152], 1,
          'N2mf R2 N2mf R2 N2mf R2 N2mf R2 N2mf R2 N2mf', null, [29]),
      _phrase('arc47', [47, 152, 47], 1, 'N2ff R1 N4ff R3 N3mf', null, [14]),
      _phrase('arc14', [14, 152, 14], 1, 'N2mf R1 N4ff R1 N3mf', null, [15]),
      _phrase('arc1', [1, 152, 1], 1, 'N1mp R1 N1pp N1pp R2 N2mp', null, [16]),
      _phrase('arc47x3', [47, 152, 47, 152, 47], 1,
          'N2mf R2 N2mf R2 N4ff R2 N2mf R2 N2mf', null, [30]),
      _phrase('arc14x3', [14, 152, 14, 152, 14], 1,
          'N2mf R1 N2mf R2 N4ff R2 N2mf R1 N2mf', null, [31]),
      _phrase('arc1x3', [1, 152, 1, 152, 1], 1,
          'N2mf R1 N1mp R1 N1mp N1mp R1 N2mp R1 N2mf', null, [32]),
      // Test 24 was flagged unstable in the log (a trailing R1 R2 R4).
      _phrase('click1soft', [1], 1, 'N1pp N1pp', null, [24], stable: false),
    ],
    gaps: [
      HapticGap(delayMs: 0, minUnits: 3, maxUnits: 4, sourceTests: [33, 34]),
      HapticGap(
          delayMs: 100,
          minUnits: 3,
          maxUnits: 4,
          sourceTests: [6, 7, 8, 22, 23]),
      // The pair and the unstable test spread wider than the rest at 100 ms.
      HapticGap(
          delayMs: 100,
          minUnits: 1,
          maxUnits: 6,
          stable: false,
          sourceTests: [5, 7, 21, 24]),
      HapticGap(delayMs: 300, minUnits: 4, maxUnits: 6, sourceTests: [35, 36]),
      HapticGap(delayMs: 700, minUnits: 6, maxUnits: 8, sourceTests: [37, 38]),
      HapticGap(
          delayMs: 1200, minUnits: 12, maxUnits: 14, sourceTests: [39, 40]),
    ],
  );

  /// The profile for a band generation ('gen5' is the MG); null when none is
  /// measured, and the caller keeps its existing way of buzzing.
  static HapticDeviceProfile? forGeneration(String? generation) =>
      generation == 'gen5' ? whoopMg : null;
}

/// Every measured device profile, by id.
final Map<String, HapticDeviceProfile> kHapticProfiles = {
  HapticDeviceProfile.whoopMg.id: HapticDeviceProfile.whoopMg,
};
