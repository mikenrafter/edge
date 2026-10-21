// Design 06 phase 1c: the input catalogue and the groups agree.
//
//  * every input id a group declares exists in the catalogue;
//  * every catalogue entry is read by at least one group (else it is dead:
//    nothing would ever recompute when it changes);
//  * every row of the plan's section 3 inventory is in the catalogue, and the
//    catalogue names no inventory row that is not there;
//  * a table input's catalogue entry is well formed (day inputs say which
//    expression gives the day; global inputs do not).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/groups/group_types.dart';
import 'package:openstrap_edge/compute/groups/input_catalogue.dart';

/// Section 3 of edge.research/design/06-phase1-plan.md, row -> input ids.
/// Skin-temp ambient reads `decoded_onehz`, so it is the `decoded` input.
const Map<String, List<String>> kInventory = {
  'decoded 1 Hz and RR': ['decoded'],
  'phone step coverage': ['step_coverage'],
  'wearing location': ['wearing'],
  'step calibration': ['step_calibration', 'step_calibration_day'],
  'device priority and coverage': ['device_coverage'],
  'wrist-off and charging events': ['events'],
  'sleep overrides and wake confirmations': [
    'sleep_override',
    'wake_confirmation',
  ],
  'vendor and wearable sleep nights': ['vendor_sleep_epoch'],
  'sessions and nap edits': ['sessions', 'session_score_mask', 'sleep_nap'],
  'baselines and history': ['baselines', 'metric_series'],
  'skin-temp ambient': ['decoded'],
  'profile': ['profile'],
  'cycle log and journal': ['cycle_log', 'journal', 'cycle_symptom'],
  'calc policies and settings': ['policy'],
  'wearable raw records': ['wearable_records'],
  'wearable source selection': ['wearable_source'],
  'time zone': ['zone'],
};

void main() {
  test('import bookkeeping and non-derive user tables are not inputs', () {
    // import_journal (D38) is restore bookkeeping; the D37 user tables are not
    // read by any group's derive. See the note in input_catalogue.dart.
    const notInputs = {
      'import_journal', 'alarm_schedule', 'symptom_entry', 'moment_label',
      'assumed_water', 'notif_fired',
    };
    final catalogued = {
      for (final s in kInputCatalogue) ...[s.id, for (final t in s.tables) t.name]
    };
    expect(catalogued.intersection(notInputs), isEmpty);
  });

  final ids = [for (final s in kInputCatalogue) s.id];
  final idSet = ids.toSet();
  final declared = <String, Set<String>>{
    for (final g in kMergedRegistry.groups)
      g.id: {for (final i in declaredInputs(g)) i.id}
  };

  test('catalogue ids are unique and non-empty', () {
    expect(ids, isNotEmpty);
    expect(ids.length, idSet.length, reason: 'duplicate input id');
  });

  test('every declared input id exists in the catalogue', () {
    final unknown = {
      for (final e in declared.entries)
        for (final i in e.value)
          if (!idSet.contains(i)) '${e.key} -> $i'
    };
    expect(unknown, isEmpty);
  });

  test('every group in the overlay is a registered group', () {
    final groupIds = {for (final g in kMergedRegistry.groups) g.id};
    expect(kGroupInputs.keys.toSet().difference(groupIds), isEmpty);
  });

  test('every catalogue entry is referenced by at least one group', () {
    final used = {for (final v in declared.values) ...v};
    final dead = idSet.difference(used);
    expect(dead, isEmpty,
        reason: 'inputs no group reads: ${dead.toList()..sort()}');
  });

  test('no group lists the same input twice', () {
    for (final g in kMergedRegistry.groups) {
      final l = [for (final i in declaredInputs(g)) i.id];
      expect(l.length, l.toSet().length, reason: g.id);
    }
  });

  test('a day-granular input is never declared with global scope', () {
    final byId = {for (final s in kInputCatalogue) s.id: s};
    final bad = {
      for (final g in kMergedRegistry.groups)
        for (final i in declaredInputs(g))
          if (byId[i.id]?.granularity == InputGranularity.day &&
              i.scope == InputScope.global)
            '${g.id} -> ${i.id}'
    };
    expect(bad, isEmpty);
  });

  test('whatever reads the decoded substrate also reads the wearable that '
      'feeds it, and every day-scoped group reads the zone it is labelled in',
      () {
    for (final e in declared.entries) {
      if (e.value.contains('decoded')) {
        expect(e.value, containsAll(['wearable_records', 'wearable_source']),
            reason: e.key);
      }
    }
    final dayScoped = {
      for (final g in kMergedRegistry.groups)
        if (declared[g.id]!.any((i) =>
            idSet.contains(i) &&
            kInputCatalogue.firstWhere((s) => s.id == i).granularity ==
                InputGranularity.day))
          g.id
    };
    expect(dayScoped, isNotEmpty);
    for (final g in dayScoped) {
      expect(declared[g], contains('zone'), reason: g);
    }
  });

  test('every section 3 inventory row is in the catalogue', () {
    final missing = {
      for (final e in kInventory.entries)
        for (final i in e.value)
          if (!idSet.contains(i)) '${e.key} -> $i'
    };
    expect(missing, isEmpty);
  });

  test('every catalogue entry belongs to an inventory row', () {
    final inInventory = {for (final v in kInventory.values) ...v};
    expect(idSet.difference(inInventory), isEmpty);
    for (final s in kInputCatalogue) {
      expect(kInventory.containsKey(s.inventoryRow), isTrue,
          reason: '${s.id}: inventoryRow "${s.inventoryRow}"');
    }
  });

  test('table, setter and decoded entries are well formed', () {
    for (final s in kInputCatalogue) {
      switch (s.kind) {
        case InputKind.table:
          expect(s.tables, isNotEmpty, reason: s.id);
          for (final t in s.tables) {
            if (s.granularity == InputGranularity.day) {
              expect(t.dayExpr, contains('{r}'), reason: '${s.id}.${t.name}');
            } else {
              expect(t.dayExpr, isNull, reason: '${s.id}.${t.name}');
            }
          }
        case InputKind.setter:
          expect(s.setterFiles, isNotEmpty, reason: s.id);
          expect(s.tables, isEmpty, reason: s.id);
        case InputKind.decoded:
          expect({for (final t in s.tables) t.name},
              {'decoded_onehz', 'decoded_rr'});
      }
    }
  });
}
