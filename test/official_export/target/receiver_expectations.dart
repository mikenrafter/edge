// What the unchanged tagged receiver must show, as violation lists.
// P1: used with candidate stubs that are EXPECTED to violate (and a control that
// must not). P2: the production mapper's output must produce no violation.
// Plain Dart (copied into the v0.12.2 package).
import 'scenario.dart';

/// What was observed in a target after importing one candidate.
class BoundaryObservation {
  const BoundaryObservation({
    required this.cursor,
    required this.deleted,
    required this.abstains,
  });
  final int? cursor;
  final Map<String, bool> deleted, abstains;
}

class UnitObservation {
  const UnitObservation({required this.definitions, required this.metrics});

  /// journal_field_def rows after import: key -> unit.
  final Map<String, String> definitions;

  /// journal_metric rows after import: (date, field) -> value.
  final Map<(String, String), double> metrics;
}

/// Violations of the prune-boundary expectations after importing a payload into
/// a fresh target. Empty means the cursor and the days around it behave as the
/// spec requires.
List<String> boundaryViolations(BoundaryObservation o) {
  final out = <String>[];
  if (o.cursor != fixtureExpectedCursor) {
    out.add('cursor ${o.cursor}, expected $fixtureExpectedCursor');
  }
  for (final day in expectedDeletedStatus.keys) {
    final want = expectedDeletedStatus[day]!, got = o.deleted[day];
    if (want && got != true) out.add('cut day $day is not labelled deleted');
    if (!want && got == true) out.add('complete day $day is labelled deleted');
  }
  for (final day in expectedAbstains.keys) {
    final want = expectedAbstains[day]!, got = o.abstains[day];
    if (want && got != true) out.add('boundary day $day does not abstain');
    if (!want && got == true) out.add('complete day $day abstains');
  }
  return out;
}

/// Violations of the unit-key expectations after importing the fork's g
/// definition into a target that already tracks the same label in mg.
List<String> unitViolations(UnitObservation o) {
  final out = <String>[];
  final unit = o.definitions[unitKeyCollision];
  if (unit != 'mg') {
    out.add('$unitKeyCollision is $unit, the populated target had mg');
  }
  if (o.metrics[('2026-10-22', unitKeyCollision)] != 200.0) {
    out.add('the populated target\'s mg history changed');
  }
  final gKeys = [
    for (final e in o.definitions.entries)
      if (e.value == 'g' && e.key != unitKeyCollision) e.key,
  ];
  if (gKeys.length != 1) {
    out.add('expected one separate g definition, found $gKeys');
  } else if (o.metrics[('2026-10-21', gKeys.single)] != 0.2) {
    out.add('imported g history is not under ${gKeys.single}');
  }
  if (o.metrics.containsKey(('2026-10-21', unitKeyCollision))) {
    out.add('g history sits under the mg key');
  }
  return out;
}
