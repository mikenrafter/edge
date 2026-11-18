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

// STUB for the red phase.
List<String> boundaryViolations(BoundaryObservation o) => const [];

// STUB for the red phase.
List<String> unitViolations(UnitObservation o) => const [];
