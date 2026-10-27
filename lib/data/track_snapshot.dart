// TracksStore owns persisted definitions; workers decode immutable snapshots.
import 'dart:convert';
import '../util/heavy.dart';
import 'track_model.dart';

@heavy
List<TrackDefinition> decodeTrackDefinitionsHeavy(
  List<Map<String, Object?>> rows,
  List<Map<String, Object?>> medications,
) {
  final meds = {for (final med in medications) 'med:${med['key']}': med};
  final definitions = <TrackDefinition>[];
  for (final row in rows) {
    final value = jsonDecode(row['payload_json'] as String);
    if (value is! Map) continue;
    final json = value.cast<String, dynamic>();
    final med = meds.remove(json['id']);
    if (med != null) {
      json.addAll({
        'name': med['label'],
        'unit': med['dose_unit'],
        'enabled': med['active'] == 1 || med['active'] == true,
      });
    } else if ((json['id'] as String).startsWith('med:')) {
      continue;
    }
    definitions.add(TrackDefinition.fromJson(json));
  }
  for (final med in meds.values) {
    definitions.add(
      TrackDefinition(
        id: 'med:${med['key']}',
        name: med['label'] as String,
        icon: 'pill',
        kind: 'consumed',
        unit: med['dose_unit'] as String? ?? '',
        enabled: med['active'] == 1 || med['active'] == true,
      ),
    );
  }
  return definitions;
}
