// WHY: counts describe affected records, and source identifiers must remain in
// the manifest even for unknown tables and failure reasons. CLAIM(export-readable-skips).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/profile.dart';
import 'package:openstrap_edge/ui2/profile/official_export_skips.dart';

void main() {
  test(
    'repeated columns count one affected workout and unknowns reveal no SQL or identities',
    () {
      final lines = summarizeOfficialSkips([
        const ExportSkip(
          'sessions',
          1,
          'Measured versus estimated provenance is unavailable',
          identity: '{"id":"private-workout"}',
          columns: ['steps'],
        ),
        const ExportSkip(
          'sessions',
          1,
          'Measured versus estimated provenance is unavailable',
          identity: '{"id":"private-workout"}',
          columns: ['cadence_spm'],
        ),
        const ExportSkip(
          'future_private_table',
          3,
          'failure with private_json_id',
          identity: 'private-json-id',
        ),
        const ExportSkip(
          'day_result',
          0,
          'Fork computed or operational state is cleared',
        ),
      ]);
      expect(lines, [
        'Workout details: 1 record. Recorded and estimated values cannot be distinguished.',
        'Other records: 3 records. These items could not be transferred safely. See the file manifest for details.',
      ]);
    },
  );
}
