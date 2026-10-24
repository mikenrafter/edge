// Design 06 phase 1d: revisioned group rows, shadow only, written by the one
// freeze point (LocalDb.putDayResult -> _ldbPutDayResult).
//
// RULES UNDER TEST
//  * An accepted day_result write stores one `group_row` per group that owns
//    a key of the bundle (found.* foundations own none), in the SAME
//    transaction as the day_result row. A refused frozen write, a skip marker
//    and a bundle with an unowned key write none (the last two still write
//    their day_result row: group rows are shadow and never block serving).
//  * Identity is (day, group, revision). A finished (finalized) revision is
//    immutable. A provisional one is replaced in place.
//  * A new revision (max + 1) is written when the group's counter, a
//    transitive ancestor's counter, or its input stamp differs from the
//    latest revision's. Unaffected groups keep their single revision.
//  * `DayResultWrite.userOverride` is the only way to replace a finished
//    revision in place.
//  * `published` stays 0 (nothing is served from group rows in 1d).
//
// ASSUMED NEW API
//   lib/data/db/group_row_store.dart
//     GroupRegistry? groupRegistryForTest;   // null => kMergedRegistry; the
//       // writer reads counters and ancestors from it. Tests reset it.
//   Row shape (schema v78, `group_row`), read here with plain SQL:
//     ancestors_json    = {ancestorGroupId: counter} over transitiveDeps
//     input_stamp_json  = {source: {scope: rev}} for the group's declaredInputs
//     payload           = UTF-8 JSON of the group's slice (sliceBundle)
//   plus sliceBundle / assembleBundle from the assembly law test.
//
// Real sqflite_ffi, same idiom as test/support/frozen_day_result_fixtures.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/compute/groups/assemble_bundle.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/groups/group_types.dart';
import 'package:openstrap_edge/compute/groups/input_catalogue.dart';
import 'package:openstrap_edge/compute/groups/slice_bundle.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/group_row_store.dart';
import 'package:openstrap_edge/data/db/input_revision_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/frozen_day_result_fixtures.dart' show freshDb, dropDb;

const String _day = '2026-03-10';
const String _other = '2026-03-11';
const int _v = 500; // a version of our own: no clash with kAlgoVersion rows

Map<String, Object?> _bundle(String day, {double rhr = 50, double tst = 420}) =>
    {
      'date': day,
      'flags': <Object?>[],
      'sleep': {
        'window': {'value': {'onset_ms': 1}}
      },
      'respiration': {'rate': 14.0},
      'hrv_night_shape': {'x': 1},
      'naps': <Object?>[],
      'zones': {'z1': 10},
      'spo2': null,
      'series': {'hrv_day': <Object?>[], 'hr_curve': <Object?>[]},
      'clinical': {
        'resting_hr': {'value': rhr}
      },
      'scalars': {
        'rhr': rhr,
        'tst_min': tst,
        'deep_min': 80.0,
        'lf_hf': 1.1,
        'resp_rate': 14.0,
        'strain': 5.0,
        'skin_temp_z': null,
      },
    };

Future<bool> _put(
  String day,
  Map<String, Object?> bundle, {
  int version = _v,
  bool finalized = false,
  bool partial = false,
  bool skipped = false,
  DayResultWrite reason = DayResultWrite.derive,
  Map<String, double?> series = const {'rhr': 50.0},
}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: version,
      payloadJson: jsonEncode(bundle),
      windowJson: '{}',
      finalized: finalized,
      partial: partial,
      skipped: skipped,
      series: series,
      reason: reason,
    );

Future<List<Map<String, Object?>>> _rows(Database db, String day,
        {String? group}) =>
    db.query('group_row',
        where: group == null ? 'day_id = ?' : 'day_id = ? AND group_id = ?',
        whereArgs: group == null ? [day] : [day, group],
        orderBy: 'group_id, revision');

Future<Map<String, List<int>>> _revs(Database db, String day) async {
  final out = <String, List<int>>{};
  for (final r in await _rows(db, day)) {
    (out[r['group_id'] as String] ??= []).add((r['revision'] as num).toInt());
  }
  return out;
}

Map<String, Object?> _slice(Map<String, Object?> bundle, String group) =>
    sliceBundle(bundle).slices[group]!;

Map<String, Object?> _payload(Map<String, Object?> row) => Map.from(
    jsonDecode(utf8.decode(row['payload'] as Uint8List)) as Map);

GroupRegistry _bumped(Map<String, int> by) => GroupRegistry(
      kMergedRegistry.registryVersion,
      [
        for (final g in kMergedRegistry.groups)
          GroupDecl(
            id: g.id,
            kind: g.kind,
            counter: g.counter + (by[g.id] ?? 0),
            members: g.members,
            api: g.api,
            deps: g.deps,
            inputs: g.inputs,
            files: g.files,
          )
      ],
    );

/// Groups whose output can change when [id] changes: [id] and its dependents.
Set<String> _downstream(GroupRegistry reg, String id) => {
      id,
      for (final g in reg.groups)
        if (transitiveDeps(reg, g.id).contains(id)) g.id
    };

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    groupRegistryForTest = null;
    db = await freshDb('group_row_freeze_test.db');
  });
  tearDown(() => groupRegistryForTest = null);
  tearDownAll(dropDb);

  final owning = sliceBundle(_bundle(_day)).slices.keys.toSet();

  test('the fixture bundle spans several groups, and a foundation owns none',
      () {
    expect(owning, containsAll([
      'sleep.stage', 'hrv.freq', 'night.rhythm', 'day.blocks',
      'activity.load', 'edge.assembly', 'day.checkpoint',
    ]));
    expect(owning.where((g) => g.startsWith('found.')), isEmpty);
  });

  group('first write', () {
    test('one revision-1 row per owning group, none for foundations',
        () async {
      expect(await _put(_day, _bundle(_day)), isTrue);
      final revs = await _revs(db, _day);
      expect(revs.keys.toSet(), owning);
      expect(revs.values, everyElement([1]));
    });

    test('a row holds the counter, ancestors, stamp, slice and flags',
        () async {
      final b = _bundle(_day);
      await _put(_day, b, finalized: true);
      for (final r in await _rows(db, _day)) {
        final g = r['group_id'] as String;
        final decl = kMergedRegistry.groups.firstWhere((x) => x.id == g);
        expect(r['counter'], decl.counter, reason: g);
        expect(jsonDecode(r['ancestors_json'] as String), {
          for (final d in transitiveDeps(kMergedRegistry, g))
            d: kMergedRegistry.groups.firstWhere((x) => x.id == d).counter
        }, reason: g);
        expect(jsonDecode(r['input_stamp_json'] as String), isA<Map>(),
            reason: g);
        expect(jsonEncode(_payload(r)), jsonEncode(_slice(b, g)), reason: g);
        expect(r['finalized'], 1, reason: g);
        expect(r['partial'], 0, reason: g);
        expect(r['published'], 0, reason: 'shadow only: $g');
        expect((r['computed_at'] as num).toInt(), greaterThan(0), reason: g);
      }
    });

    test('the rows assemble to the stored day_result payload, byte for byte',
        () async {
      final b = _bundle(_day);
      await _put(_day, b);
      final slices = {
        for (final r in await _rows(db, _day))
          r['group_id'] as String: _payload(r)
      };
      final stored = (await db.query('day_result')).single['payload_json']
          as String;
      final order = sliceBundle(
              Map<String, Object?>.from(jsonDecode(stored) as Map))
          .keyOrder;
      expect(jsonEncode(assembleBundle(slices, order)), stored);
    });

    test('revisions are per day', () async {
      await _put(_day, _bundle(_day));
      await _put(_other, _bundle(_other));
      expect((await _revs(db, _other)).values, everyElement([1]));
    });

    test('a partial write is marked partial', () async {
      await _put(_day, _bundle(_day), partial: true);
      final rs = await _rows(db, _day);
      expect(rs, isNotEmpty);
      expect(rs.map((r) => r['partial']), everyElement(1));
    });
  });

  group('provisional rows', () {
    test('a provisional row is replaced in place, not stacked', () async {
      await _put(_day, _bundle(_day, tst: 400), partial: true);
      final first = await _rows(db, _day, group: 'sleep.stage');
      await _put(_day, _bundle(_day, tst: 410));
      final rs = await _rows(db, _day, group: 'sleep.stage');
      expect(rs, hasLength(1));
      expect(rs.single['revision'], 1);
      expect(rs.single['partial'], 0);
      expect(_payload(rs.single), _slice(_bundle(_day, tst: 410), 'sleep.stage'));
      expect(first.single['partial'], 1);
    });
  });

  group('a finished revision is immutable', () {
    test('a later accepted write with the same counters leaves it untouched',
        () async {
      await _put(_day, _bundle(_day, tst: 400), finalized: true);
      final before = await _rows(db, _day);
      // A new algo version is a sibling day_result row, so it is accepted;
      // nothing in the group's counter, ancestors or inputs moved.
      expect(await _put(_day, _bundle(_day, tst: 999), version: _v + 1,
          finalized: true), isTrue);
      expect(await _rows(db, _day), before);
    });

    test('a finished row of one version blocks no other day', () async {
      await _put(_day, _bundle(_day), finalized: true);
      await _put(_other, _bundle(_other, tst: 300));
      expect((await _rows(db, _other)), isNotEmpty);
    });
  });

  group('a new revision when something upstream moved', () {
    test('a group counter bump writes revision 2 for the group and its '
        'dependents only; revision 1 stays byte-identical', () async {
      await _put(_day, _bundle(_day, tst: 400), finalized: true);
      final before = await _rows(db, _day);
      groupRegistryForTest = _bumped({'sleep.stage': 1});
      await _put(_day, _bundle(_day, tst: 450), version: _v + 1, finalized: true);

      final hit = _downstream(groupRegistryForTest!, 'sleep.stage');
      final unaffected = owning.difference(hit);
      expect(hit.intersection(owning), containsAll(['sleep.stage', 'edge.assembly']));
      expect(unaffected, isNotEmpty, reason: 'the bump must not reach everyone');

      final revs = await _revs(db, _day);
      for (final g in owning) {
        expect(revs[g], hit.contains(g) ? [1, 2] : [1], reason: g);
      }
      // revision 1 untouched
      final after = await _rows(db, _day);
      expect(after.where((r) => r['revision'] == 1).toList(),
          before.toList());
      final r2 = (await _rows(db, _day, group: 'sleep.stage'))
          .firstWhere((r) => r['revision'] == 2);
      // The declared counter plus the bump: analytics registries move their
      // own counters (sleep.stage is 2 from analytics #99 on).
      expect(r2['counter'], kMergedRegistry.groups
          .firstWhere((x) => x.id == 'sleep.stage').counter + 1);
      expect(_payload(r2), _slice(_bundle(_day, tst: 450), 'sleep.stage'));
    });

    test('an ancestor-only counter bump (a foundation) reaches its dependents',
        () async {
      await _put(_day, _bundle(_day), finalized: true);
      groupRegistryForTest = _bumped({'found.calibration': 1});
      await _put(_day, _bundle(_day), version: _v + 1, finalized: true);
      final hit = _downstream(groupRegistryForTest!, 'found.calibration');
      expect(hit.intersection(owning), isNotEmpty);
      final revs = await _revs(db, _day);
      for (final g in owning) {
        expect(revs[g]!.length, hit.contains(g) ? 2 : 1, reason: g);
      }
      for (final g in hit.intersection(owning)) {
        final r2 = (await _rows(db, _day, group: g))
            .firstWhere((r) => r['revision'] == 2);
        expect((jsonDecode(r2['ancestors_json'] as String)
            as Map)['found.calibration'], 2, reason: g);
        expect(r2['counter'], kMergedRegistry.groups
            .firstWhere((x) => x.id == g).counter, reason: '$g own counter');
      }
    });

    test('a day-scoped input revision bump reaches the groups reading it',
        () async {
      await _put(_day, _bundle(_day), finalized: true);
      await bumpInputRev('sleep_override', _day);
      await _put(_day, _bundle(_day, tst: 430), version: _v + 1, finalized: true);

      final readers = {
        for (final g in kMergedRegistry.groups)
          if (declaredInputs(g).any((i) => i.id == 'sleep_override')) g.id
      };
      expect(readers, contains('sleep.stage'));
      // Groups that neither read the input nor sit downstream of a reader.
      final related = {
        for (final r in readers) ..._downstream(kMergedRegistry, r)
      };
      final revs = await _revs(db, _day);
      for (final g in readers.intersection(owning)) {
        expect(revs[g], [1, 2], reason: g);
      }
      for (final g in owning.difference(related)) {
        expect(revs[g], [1], reason: '$g does not read sleep_override');
      }
      final r2 = (await _rows(db, _day, group: 'sleep.stage'))
          .firstWhere((r) => r['revision'] == 2);
      expect(
          ((jsonDecode(r2['input_stamp_json'] as String)
              as Map)['sleep_override'] as Map)[_day],
          1);
    });

    test('an input bump for another day does not move this day', () async {
      await _put(_day, _bundle(_day), finalized: true);
      await bumpInputRev('sleep_override', _other);
      await _put(_day, _bundle(_day, tst: 430), version: _v + 1, finalized: true);
      expect((await _revs(db, _day)).values, everyElement([1]));
    });

    test('a provisional write never stacks revisions without a reason',
        () async {
      for (var i = 0; i < 3; i++) {
        await _put(_day, _bundle(_day, tst: 400.0 + i));
      }
      expect((await _revs(db, _day)).values, everyElement([1]));
    });
  });

  group('the user re-derive is the only override', () {
    test('userOverride replaces a finished revision in place', () async {
      await _put(_day, _bundle(_day, tst: 400), finalized: true);
      final before = await _rows(db, _day, group: 'sleep.stage');
      expect(await _put(_day, _bundle(_day, tst: 480), finalized: true,
          reason: DayResultWrite.userOverride), isTrue);
      final rs = await _rows(db, _day, group: 'sleep.stage');
      expect(rs, hasLength(1));
      expect(rs.single['revision'], 1);
      expect(_payload(rs.single), _slice(_bundle(_day, tst: 480), 'sleep.stage'));
      expect(_payload(rs.single), isNot(_payload(before.single)));
    });

    test('a plain derive at the same version cannot', () async {
      await _put(_day, _bundle(_day, tst: 400), finalized: true);
      final before = await _rows(db, _day);
      expect(await _put(_day, _bundle(_day, tst: 480), finalized: true),
          isFalse);
      expect(await _rows(db, _day), before);
    });
  });

  group('written only when the day_result write is accepted', () {
    test('a refused frozen write writes no group rows, even if a counter '
        'moved', () async {
      await _put(_day, _bundle(_day, tst: 400), finalized: true);
      final before = await _rows(db, _day);
      groupRegistryForTest = _bumped({'sleep.stage': 1, 'found.core': 1});
      expect(await _put(_day, _bundle(_day, tst: 480)), isFalse);
      expect(await _rows(db, _day), before);
    });

    test('a refused write leaves the settled marker alone, an accepted one '
        'clears it', () async {
      await _put(_day, _bundle(_day), finalized: true);
      await LocalDb.putSettledDay(_day, _v, own: 'a', prev: null);
      expect(await _put(_day, _bundle(_day, tst: 1)), isFalse);
      expect((await LocalDb.settledFingerprints(_v)).keys, contains(_day));
      expect(await _put(_other, _bundle(_other)), isTrue);
      await LocalDb.putSettledDay(_other, _v, own: 'a', prev: null);
      expect(await _put(_other, _bundle(_other, tst: 2)), isTrue);
      expect((await LocalDb.settledFingerprints(_v)).keys,
          isNot(contains(_other)));
      expect(await _rows(db, _other), isNotEmpty);
    });

    test('the group rows share the transaction: a failed day write leaves '
        'none behind', () async {
      await db.execute('CREATE TRIGGER fail_series BEFORE INSERT ON '
          "metric_series BEGIN SELECT RAISE(ABORT, 'boom'); END");
      await expectLater(_put(_day, _bundle(_day)), throwsA(anything));
      expect(await db.query('day_result'), isEmpty);
      expect(await _rows(db, _day), isEmpty);
    });

    test('a skip marker writes its day_result row and no group rows',
        () async {
      final ok = await LocalDb.putDayResult(
        dayId: _day,
        algoVersion: _v,
        payloadJson: jsonEncode({'skipped': true, 'reason': 'no_data'}),
        windowJson: '{}',
        skipped: true,
      );
      expect(ok, isTrue);
      expect(await db.query('day_result'), hasLength(1));
      expect(await _rows(db, _day), isEmpty);
    });

    test('a bundle with an unowned key still serves, with no group rows',
        () async {
      final b = _bundle(_day)..['mystery_key'] = 1;
      expect(await _put(_day, b), isTrue);
      expect(await db.query('day_result'), hasLength(1));
      expect(await _rows(db, _day), isEmpty,
          reason: 'a half-sliced day must not be stored as if complete');
    });

    test('an import snapshot gets group rows too', () async {
      final b = <String, Object?>{
        'date': _day,
        'imported': true,
        'source': 'whoop_export',
        'flags': ['IMPORTED_WHOOP_BETA'],
        'clinical': <String, Object?>{},
        'scalars': {'rhr': null, 'readiness': 66.0},
      };
      expect(await _put(_day, b, version: kAlgoVersion, finalized: true),
          isTrue);
      expect(await _rows(db, _day, group: 'edge.assembly'), hasLength(1));
    });
  });

  test('"Delete everything" empties group_row', () async {
    await _put(_day, _bundle(_day));
    expect(await _rows(db, _day), isNotEmpty);
    await LocalDb.wipeAll();
    expect(await db.query('group_row'), isEmpty);
  });
}
