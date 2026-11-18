// The coverage gate's own behavior, on a small literal profile.
//
// WHY: the real profile covers ~120 tables, so a gate that silently accepted
// everything would still look green there. These controls fail the gate on
// each shape it must reject. CLAIM(official-export-accounted-identities).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/profile.dart';

import 'support.dart';

const _profile = OfficialProfile(
  tables: {
    'person': TableProfile(
      policy: TablePolicy.kept,
      meaning: 'people',
      evidence: 'x',
      dest: 'person',
      keep: ['id', 'name'],
      merge: MergeKey(['id'], MergeRule.plainReplace),
    ),
    'cache': TableProfile(
      policy: TablePolicy.dropped,
      meaning: 'cache',
      evidence: 'x',
      dropped: ['k', 'v'],
    ),
    'legacy': TableProfile(
      policy: TablePolicy.dropped,
      meaning: 'old',
      evidence: 'x',
      dropped: ['a'],
      optional: true,
    ),
  },
  carriers: [],
  enums: [],
);

void main() {
  test('the literal profile is internally consistent', () {
    expect(_profile.problems(), isEmpty);
  });

  test('exactly matching schema has no gaps; an absent optional table is fine',
      () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT PRIMARY KEY, name TEXT)',
      'CREATE TABLE cache(k TEXT, v TEXT)',
    ]);
    expect(_profile.coverage(c), isEmpty);
  });

  test('rejects an unclassified table', () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT PRIMARY KEY, name TEXT)',
      'CREATE TABLE cache(k TEXT, v TEXT)',
      'CREATE TABLE surprise(z INTEGER)',
    ]);
    expect(_profile.coverage(c).map((g) => g.text), [
      'unclassified table surprise',
    ]);
  });

  test('rejects an unclassified column on a kept AND on a dropped table',
      () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT PRIMARY KEY, name TEXT, secret TEXT)',
      'CREATE TABLE cache(k TEXT, v TEXT, extra TEXT)',
    ]);
    expect(_profile.coverage(c).map((g) => g.text).toSet(), {
      'unclassified column person.secret',
      'unclassified column cache.extra',
    });
  });

  test('rejects a profile column the schema no longer has', () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT PRIMARY KEY)',
      'CREATE TABLE cache(k TEXT, v TEXT)',
    ]);
    expect(_profile.coverage(c).map((g) => g.text), [
      'profile column person.name is not in the schema',
    ]);
  });

  test('rejects a missing required table', () async {
    final c = await catalogOf(['CREATE TABLE person(id TEXT, name TEXT)']);
    expect(_profile.coverage(c).map((g) => g.text), [
      'profile table cache is absent and not optional',
    ]);
  });

  test('rejects a kept table that is WITHOUT ROWID', () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT PRIMARY KEY, name TEXT) WITHOUT ROWID',
      'CREATE TABLE cache(k TEXT, v TEXT)',
    ]);
    expect(_profile.coverage(c).single, isA<UnsupportedShape>());
  });

  test('a WITHOUT ROWID table is fine when it is not carried (policy D)',
      () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT PRIMARY KEY, name TEXT)',
      'CREATE TABLE cache(k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID',
    ]);
    expect(_profile.coverage(c), isEmpty);
  });

  test('rejects a kept table whose columns shadow every rowid alias', () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT, name TEXT, rowid INTEGER, oid INTEGER, '
          '_rowid_ INTEGER)',
      'CREATE TABLE cache(k TEXT, v TEXT)',
    ]);
    final gaps = _profile.coverage(c);
    expect(gaps.whereType<UnsupportedShape>(), hasLength(1));
  });

  test('one shadowed alias still leaves a usable one', () async {
    final c = await catalogOf([
      'CREATE TABLE person(id TEXT, name TEXT, rowid TEXT)',
      'CREATE TABLE cache(k TEXT, v TEXT)',
    ]);
    // `rowid` is a real column, so the profile sees it as unclassified, but the
    // shape itself is usable through _rowid_.
    final gaps = _profile.coverage(c);
    expect(gaps.whereType<UnsupportedShape>(), isEmpty);
    expect(c.tables['person']!.rowidAlias, '_rowid_');
  });

  test('a table named sqliteX is user data, not an SQLite internal', () async {
    final c = await catalogOf(['CREATE TABLE sqliteX(a TEXT)']);
    expect(c.tables.keys, contains('sqliteX'));
  });

  test('problems() catches policy/column contradictions', () {
    const bad = OfficialProfile(
      tables: {
        'a': TableProfile(
          policy: TablePolicy.kept,
          meaning: 'x',
          evidence: 'x',
          keep: ['id', 'id'],
        ),
        'b': TableProfile(
          policy: TablePolicy.dropped,
          meaning: 'x',
          evidence: 'x',
          keep: ['id'],
          merge: MergeKey(['id'], MergeRule.plainReplace),
        ),
      },
      carriers: [],
      enums: [],
    );
    expect(bad.problems(), containsAll([
      'a.id is classified twice',
      'a: K needs a dest',
      'a: no merge key',
      'b: D must list columns as dropped',
      'b: D has a merge',
    ]));
  });
}
