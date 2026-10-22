// Design 06 phase 1e: compare-and-set publication, and closure validation.
//
// Owner decision (1d): the manifest is NOT written inside `_ldbPutDayResult`'s
// transaction. It is published in the same post-commit shadow transaction as
// the group rows, compare-and-set on the prior manifest_seq. Nothing is served
// from it in phase 1.
//
// "Pending invalidation" (design 06 §publication rule 2) maps, today, to an
// input_revision bump that happened after the revision's input stamp was
// captured and has not been re-derived yet: either a stamped (source, scope)
// whose rev is now higher, or a (source, scope) in the group's window that the
// stamp did not hold. A queued `compute_jobs` derive row is NOT an
// invalidation: its scope is the global 'derive', it names no day, and the
// input bump it was queued for is already visible as a revision move.
//
// ASSUMED NEW API
//   lib/compute/groups/publication.dart
//     enum ClosureReason { unpinned, inputMoved, counterMoved, missingRevision }
//     class ClosureProblem { String group; ClosureReason reason; }
//     class ClosureVerdict { bool get ok; List<ClosureProblem> problems; }
//     Future<ClosureVerdict> validateClosure(DatabaseExecutor db,
//         {required String dayId, required Map<String,int> selected});
//       // reads group_row (stored counter, ancestors, input_stamp_json) and
//       // compares with the CURRENT registry (groupRegistryForTest ??
//       // kMergedRegistry) and the current input revisions. No payload reads.
//     sealed class PublishResult;  Published(int seq);
//       PublishRefused(PublishRefusal reason, List<ClosureProblem> problems);
//       PublishFailed(Object error);
//     enum PublishRefusal { priorMoved, closure }
//     Future<PublishResult> publish(Database db, {
//         required String dayId, required int? expectedPriorSeq,
//         required Map<String,int> selected, required List<String> keyOrder,
//         required String bundleSha, required String seriesSha,
//         required Map<String,Object?> freshness, int? nowMs});
//       // ONE transaction: re-read MAX(manifest_seq); refuse when it differs
//       // from expectedPriorSeq (null = no manifest yet); validateClosure;
//       // insert manifest_seq + 1; mark exactly `selected` published = 1.
//       // Never throws. A refusal changes nothing.
//   lib/data/db/manifest_store.dart
//     Future<Manifest?> latestManifest(DatabaseExecutor, String dayId, ...)
//   lib/compute/groups/manifest_codec.dart  Manifest (see roundtrip test)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/groups/group_types.dart';
import 'package:openstrap_edge/compute/groups/manifest_codec.dart';
import 'package:openstrap_edge/compute/groups/publication.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/group_row_store.dart';
import 'package:openstrap_edge/data/db/input_revision_store.dart';
import 'package:openstrap_edge/data/db/manifest_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/frozen_day_result_fixtures.dart' show freshDb, dropDb;

const String _day = '2026-03-10';

Map<String, Object?> _bundle() => {
      'date': _day,
      'sleep': {'a': 1},
      'scalars': <String, Object?>{'rhr': 50.0},
    };

/// A pinned write (a stamp captured before the inputs were read), the only
/// kind whose revisions may be published.
Future<bool> _putPinned({int version = 500}) async {
  final stamp = await captureInputStamp(_day);
  return LocalDb.putDayResult(
    dayId: _day,
    algoVersion: version,
    payloadJson: jsonEncode(_bundle()),
    windowJson: '{}',
    series: const {'rhr': 50.0},
    inputStamp: stamp,
  );
}

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

/// A newer finished revision of [group], as a second assembly would have
/// written it (same stamp and counters: a valid closure), not yet published.
Future<void> _fork(Database db, String group, int revision) async {
  final r = (await db.query('group_row',
      where: 'day_id = ? AND group_id = ? AND revision = 1',
      whereArgs: [_day, group])).single;
  await db.insert('group_row', {
    ...r,
    'revision': revision,
    'finalized': 1,
    'published': 0,
  });
}

Future<List<Map<String, Object?>>> _published(Database db) => db.query(
    'group_row',
    where: 'day_id = ? AND published = 1',
    whereArgs: [_day],
    orderBy: 'group_id, revision');

Future<PublishResult> _publish(Database db, Manifest base,
        Map<String, int> selected, int? prior) =>
    publish(db,
        dayId: _day,
        expectedPriorSeq: prior,
        selected: selected,
        keyOrder: base.keyOrder,
        bundleSha: base.bundleSha,
        seriesSha: base.seriesSha,
        freshness: base.freshness);

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    groupRegistryForTest = null;
    db = await freshDb('manifest_cas.db');
  });
  tearDown(() => groupRegistryForTest = null);
  tearDownAll(dropDb);

  group('compare-and-set', () {
    late Manifest m1;
    setUp(() async {
      expect(await _putPinned(), isTrue);
      m1 = (await latestManifest(db, _day))!;
      expect(m1.manifestSeq, 1);
    });

    test('the first publish expects no prior and gets seq 1; a second '
        'publish that still expects none is refused', () async {
      await db.delete('day_manifest');
      await db.update('group_row', {'published': 0});
      final first = await _publish(db, m1, m1.selected, null);
      expect(first, isA<Published>());
      expect((first as Published).seq, 1);
      final again = await _publish(db, m1, m1.selected, null);
      expect(again, isA<PublishRefused>());
      expect((again as PublishRefused).reason, PublishRefusal.priorMoved);
      expect(await db.query('day_manifest'), hasLength(1));
    });

    test('two assemblies started from seq 1: the slower is refused, leaves '
        'no published rows and no manifest', () async {
      await _fork(db, 'sleep.stage', 2); // assembly A's revision
      await _fork(db, 'sleep.stage', 3); // assembly B's revision
      final a = {...m1.selected, 'sleep.stage': 2};
      final b = {...m1.selected, 'sleep.stage': 3};

      final fast = await _publish(db, m1, a, 1);
      expect(fast, isA<Published>());
      expect((fast as Published).seq, 2);

      final slow = await _publish(db, m1, b, 1);
      expect(slow, isA<PublishRefused>());
      expect((slow as PublishRefused).reason, PublishRefusal.priorMoved);

      final seqs = [
        for (final r in await db.query('day_manifest', orderBy: 'manifest_seq'))
          r['manifest_seq']
      ];
      expect(seqs, [1, 2], reason: 'no manifest for the refused assembly');
      expect((await latestManifest(db, _day))!.selected, a);
      final pub = await _published(db);
      expect({for (final r in pub) r['group_id'] as String: r['revision']}, a);
      final refusedRow = await db.query('group_row',
          where: "group_id = 'sleep.stage' AND revision = 3");
      expect(refusedRow.single['published'], 0,
          reason: 'the refused assembly marked nothing');
    });

    test('truly concurrent: exactly one of two wins, the loser leaves '
        'nothing behind', () async {
      await _fork(db, 'sleep.stage', 2);
      await _fork(db, 'sleep.stage', 3);
      final a = {...m1.selected, 'sleep.stage': 2};
      final b = {...m1.selected, 'sleep.stage': 3};
      final rs = await Future.wait([
        _publish(db, m1, a, 1),
        _publish(db, m1, b, 1),
      ]);
      expect(rs.whereType<Published>(), hasLength(1));
      expect(rs.whereType<PublishRefused>(), hasLength(1));
      final winner = rs.first is Published ? a : b;
      expect(await db.query('day_manifest'), hasLength(2));
      expect((await latestManifest(db, _day))!.selected, winner);
      expect({
        for (final r in await _published(db)) r['group_id'] as String: r['revision']
      }, winner);
    });

    test('a stale expectedPriorSeq (too high) is refused too', () async {
      final r = await _publish(db, m1, m1.selected, 5);
      expect(r, isA<PublishRefused>());
      expect((r as PublishRefused).reason, PublishRefusal.priorMoved);
      expect(await db.query('day_manifest'), hasLength(1));
    });

    test('publish never throws: a failing manifest insert is a PublishFailed '
        'and rolls its own marks back', () async {
      await _fork(db, 'sleep.stage', 2);
      await db.execute('CREATE TRIGGER mf_boom BEFORE INSERT ON day_manifest '
          "BEGIN SELECT RAISE(ABORT, 'boom'); END");
      final r = await _publish(
          db, m1, {...m1.selected, 'sleep.stage': 2}, 1);
      expect(r, isA<PublishFailed>());
      expect(
          (await db.query('group_row',
                  where: "group_id = 'sleep.stage' AND revision = 2"))
              .single['published'],
          0);
      expect(await db.query('day_manifest'), hasLength(1));
    });
  });

  group('closure validation', () {
    Future<Map<String, int>> selectedNow() async =>
        (await latestManifest(db, _day))!.selected;

    test('a clean pinned day is valid, and publish published it', () async {
      expect(await _putPinned(), isTrue);
      final v = await validateClosure(db, dayId: _day, selected: await selectedNow());
      expect(v.problems, isEmpty);
      expect(v.ok, isTrue);
    });

    test('a stamped input that moved since capture refuses', () async {
      await bumpInputRev('sleep_override', _day); // rev 1 before capture
      expect(await _putPinned(), isTrue);
      final sel = await selectedNow();
      await bumpInputRev('sleep_override', _day); // rev 2 after
      final v = await validateClosure(db, dayId: _day, selected: sel);
      expect(v.ok, isFalse);
      expect(
          v.problems.where((p) =>
              p.group == 'sleep.stage' && p.reason == ClosureReason.inputMoved),
          isNotEmpty);
    });

    test('an input scope the stamp never held (a pending invalidation: the '
        'bump landed after capture) refuses', () async {
      expect(await _putPinned(), isTrue);
      final sel = await selectedNow();
      await bumpInputRev('sleep_override', _day);
      final v = await validateClosure(db, dayId: _day, selected: sel);
      expect(v.ok, isFalse);
      expect(v.problems.map((p) => p.reason), contains(ClosureReason.inputMoved));
    });

    test('a bump on a day the group does not read does not refuse', () async {
      expect(await _putPinned(), isTrue);
      final sel = await selectedNow();
      await bumpInputRev('sleep_override', '2025-01-01');
      expect((await validateClosure(db, dayId: _day, selected: sel)).ok, isTrue);
    });

    test('a queued derive job is not an invalidation by itself', () async {
      expect(await _putPinned(), isTrue);
      final sel = await selectedNow();
      await db.insert('compute_jobs', {
        'id': 'derive_x', 'type': 'derive_light', 'scope': 'derive',
        'priority': 100, 'state': 'queued', 'attempts': 0,
        'created_at': 1, 'updated_at': 1,
      });
      expect((await validateClosure(db, dayId: _day, selected: sel)).ok, isTrue);
    });

    test('an unpinned stamp is never valid', () async {
      // No stamp: stored with "_unpinned":true.
      expect(
          await LocalDb.putDayResult(
              dayId: _day,
              algoVersion: 500,
              payloadJson: jsonEncode(_bundle()),
              windowJson: '{}',
              series: const {'rhr': 50.0}),
          isTrue);
      expect(await db.query('day_manifest'), isEmpty,
          reason: 'an unpinned day publishes nothing');
      final latest = {
        for (final r in await db.query('group_row'))
          r['group_id'] as String: (r['revision'] as num).toInt()
      };
      final v = await validateClosure(db, dayId: _day, selected: latest);
      expect(v.ok, isFalse);
      expect(v.problems.map((p) => p.reason).toSet(), {ClosureReason.unpinned});
      expect({for (final p in v.problems) p.group}, latest.keys.toSet());
      expect(await _published(db), isEmpty);
    });

    test('a moved counter refuses its group and its dependents only', () async {
      expect(await _putPinned(), isTrue);
      final sel = await selectedNow();
      groupRegistryForTest = _bumped({'sleep.stage': 1});
      final v = await validateClosure(db, dayId: _day, selected: sel);
      expect(v.ok, isFalse);
      final hit = {for (final p in v.problems) p.group};
      expect(hit, contains('sleep.stage'));
      expect(v.problems.map((p) => p.reason).toSet(), {ClosureReason.counterMoved});
      expect(hit.length, lessThan(sel.length),
          reason: 'unrelated groups stay valid');
    });

    test('an ancestor-only counter move refuses the dependent', () async {
      expect(await _putPinned(), isTrue);
      final sel = await selectedNow();
      groupRegistryForTest = _bumped({'found.calibration': 1});
      final v = await validateClosure(db, dayId: _day, selected: sel);
      expect(v.ok, isFalse);
      expect(v.problems.map((p) => p.reason), contains(ClosureReason.counterMoved));
    });

    test('a selected revision that does not exist refuses', () async {
      expect(await _putPinned(), isTrue);
      final v = await validateClosure(db,
          dayId: _day, selected: {...await selectedNow(), 'sleep.stage': 9});
      expect(v.ok, isFalse);
      expect(
          v.problems.where((p) =>
              p.group == 'sleep.stage' &&
              p.reason == ClosureReason.missingRevision),
          isNotEmpty);
    });

    test('publish refuses a stale closure, marks nothing, adds no manifest',
        () async {
      expect(await _putPinned(), isTrue);
      final m1 = (await latestManifest(db, _day))!;
      await _fork(db, 'sleep.stage', 2);
      await bumpInputRev('sleep_override', _day);
      final r = await _publish(db, m1, {...m1.selected, 'sleep.stage': 2}, 1);
      expect(r, isA<PublishRefused>());
      expect((r as PublishRefused).reason, PublishRefusal.closure);
      expect(r.problems, isNotEmpty);
      expect(await db.query('day_manifest'), hasLength(1));
      expect(
          (await db.query('group_row',
                  where: "group_id = 'sleep.stage' AND revision = 2"))
              .single['published'],
          0);
    });
  });
}
