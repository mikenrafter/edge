// The target DDL the profile carries (spec §4.1, P1 red: includes `imported`).
//
// WHY: the official file must be created from the tagged release's ACTUAL
// create-plus-open-repair DDL. `day_result.imported` exists only after the
// release's on-open repair; a layout copied from its CREATE literal lacks it
// and the importer's own repair would then add it to a file we claimed was
// final. CLAIM(official-export-no-fork-results).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/profile.dart';
import 'package:openstrap_edge/data/official_export/profile_target.dart';
import 'package:openstrap_edge/data/official_export/schema_catalog.dart';

import 'support.dart';

Future<SchemaCatalog> _build() async {
  // Tables before indexes/triggers/views so every object finds its table.
  const order = ['table', 'index', 'view', 'trigger'];
  final ddl = [
    for (final type in order)
      for (final o in officialTargetObjects)
        if (o.type == type) o.sql,
  ];
  return catalogOf(ddl);
}

void main() {
  test('constants name the tagged release exactly', () {
    expect(officialTargetTag, 'v0.12.2');
    expect(officialTargetSha, 'cd64eaa89948409ccffbea19ee48d7bd22dcb808');
    expect(officialTargetSchema, 62);
    expect(officialTargetAlgorithm, 124);
  });

  test('the DDL list is the whole repaired target (77 tables)', () {
    expect(
      officialTargetObjects.where((o) => o.type == 'table'),
      hasLength(77),
    );
  });

  test('executing the DDL reproduces the captured target tables and columns',
      () async {
    final built = await _build();
    final captured = loadCapture('target_schema_62.json');
    expect(
      built.tables.map((n, t) => MapEntry(n, [
        for (final c in t.columns) (c.name, c.type, c.notNull, c.defaultValue, c.pk),
      ])),
      captured.tables.map((n, t) => MapEntry(n, [
        for (final c in t.columns) (c.name, c.type, c.notNull, c.defaultValue, c.pk),
      ])),
    );
  });

  test('day_result is created WITH the receiver-owned `imported` column',
      () async {
    final built = await _build();
    final imported = built.tables['day_result']!.columns.singleWhere(
      (c) => c.name == 'imported',
    );
    expect(imported.type, 'INTEGER');
    expect(imported.notNull, isTrue);
    expect(imported.defaultValue, '0');
  });

  test('the captured target itself has `imported` (the DDL is not invented)',
      () {
    expect(
      loadCapture('target_schema_62.json').tables['day_result']!.columnNames,
      contains('imported'),
    );
  });

  test('the fork day_result has no `imported`: copying its layout is wrong',
      () {
    expect(
      loadCapture('fork_schema_92.json').tables['day_result']!.columnNames,
      isNot(contains('imported')),
    );
  });
}
