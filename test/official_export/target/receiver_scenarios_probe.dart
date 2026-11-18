// Runs candidate official files through the UNCHANGED v0.12.2 receiver
// (`LocalDb.importFromDbFile`, the plain-DB entry point) and checks the prune
// boundary and the unit-key scenarios. Copied into the tagged package by
// harness/run_receiver_scenarios.sh as receiver_scenarios_test.dart.
//
// WHY: only the real receiver can say what a cursor value means ("this day is
// deleted", "this day abstains") and what a REPLACE does to a same-key custom
// definition. A mapper-only test cannot. CLAIM(official-export-actual-receiver),
// CLAIM(official-export-prune-edge), CLAIM(official-export-unit-keys).
//
// Env: CANDIDATES_DIR holds naive.db, nocursor.db, policy.db, units_naive.db,
// units_control.db written by the fork-side write_candidates probe.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/hyrox_store.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'receiver_expectations.dart';
import 'scenario.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

String get _dir => Platform.environment['CANDIDATES_DIR'] ?? 'build/official_probe/candidates';
String get _out => Platform.environment['OFFICIAL_PROBE_OUT'] ?? 'build/official_probe';

Future<T> _withFreshTarget<T>(
  Future<T> Function(Database db) body, {
  Future<void> Function(Database db)? populate,
}) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final root = await Directory.systemTemp.createTemp('official_receiver_');
  PathProviderPlatform.instance = _Paths(root.path);
  LocalDb.dbName = '${root.path}/official.db';
  try {
    final db = await LocalDb.instance;
    expect(LocalDb.schemaVersion, 62);
    if (populate != null) await populate(db);
    return await body(db);
  } finally {
    await LocalDb.close();
    
    await root.delete(recursive: true);
  }
}

Future<BoundaryObservation> _boundary(String candidate) => _withFreshTarget((db) async {
  await LocalDb.importFromDbFile('$_dir/$candidate');
  // WHY: a cursor verdict alone does not prove complete restored input exists.
  // Hand-counted hourly fixture span, d4..d7 = 24 parents, d8 = one parent.
  for (var day = 4; day <= 8; day++) {
    final rows = await db.rawQuery(
      "SELECT rec_ts, hr FROM decoded_onehz WHERE device_id = '' AND rec_ts >= ? AND rec_ts < ? ORDER BY rec_ts",
      [dayStartEpoch(day), dayStartEpoch(day + 1)],
    );
    expect(rows.map((r) => r['rec_ts']).toList(), [
      for (var hour = 0; hour < (day == 8 ? 1 : 24); hour++) dayStartEpoch(day) + hour * 3600,
    ], reason: '$candidate d$day exact decoded rows');
    expect(rows.map((r) => r['hr']).toSet(), {55});
  }
  final cursor = await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
  return BoundaryObservation(
    cursor: cursor,
    deleted: {for (final d in [d3, d4, d5]) d: await LocalDb.decodedPrunedFor(d)},
    abstains: {
      for (final d in [d3, d4, d5]) d: DerivationEngine.windowTruncatedByPrune(d, cursor),
    },
  );
});

Future<UnitObservation> _units(String candidate) => _withFreshTarget(
  (db) async {
    await LocalDb.importFromDbFile('$_dir/$candidate');
    return UnitObservation(
      definitions: {
        for (final r in await db.query('journal_field_def')) '${r['key']}': '${r['unit']}',
      },
      metrics: {
        for (final r in await db.query('journal_metric'))
          ('${r['date']}', '${r['field']}'): (r['value'] as num).toDouble(),
      },
    );
  },
  populate: (db) async {
    // The populated official target already tracks caffeine in MILLIGRAMS.
    await db.insert('journal_field_def', {
      'key': unitKeyCollision, 'label': 'Caffeine', 'kind': 'dose',
      'unit': 'mg', 'max_value': 1000.0, 'step': 10.0, 'has_time': 0, 'created_at': 1,
    });
    await db.insert('journal_metric', {
      'date': '2026-10-22', 'field': unitKeyCollision, 'value': 200.0, 'updated_at': 1,
    });
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{
    'fork_head': Platform.environment['OFFICIAL_FORK_HEAD'],
    'fork_status_porcelain': Platform.environment['OFFICIAL_FORK_STATUS'],
  };
  tearDownAll(() async {
    Directory(_out).createSync(recursive: true);
    File('$_out/receiver-scenarios.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  });

  test('process zone is UTC (the literals are UTC epochs)', () {
    expect(DateTime.utc(2026, 7, 1).toLocal().timeZoneOffset, Duration.zero);
  });

  group('prune boundary through the real receiver', () {
    test('control: the policy payload satisfies every expectation', () async {
      final o = await _boundary('policy.db');
      report['boundary/policy'] = {'cursor': o.cursor, 'deleted': o.deleted, 'abstains': o.abstains};
      expect(boundaryViolations(o), isEmpty);
    });

    test('naive copy: the fork-live cursor blocks complete restored days (inverse)',
        () async {
      final o = await _boundary('naive.db');
      report['boundary/naive'] = {'cursor': o.cursor, 'deleted': o.deleted, 'abstains': o.abstains};
      expect(boundaryViolations(o), contains('cursor ${o.cursor}, expected $fixtureExpectedCursor'));
      expect(boundaryViolations(o), contains('complete day $d4 is labelled deleted'));
    });

    test('no cursor row: the cut oldest day is not labelled deleted', () async {
      final o = await _boundary('nocursor.db');
      report['boundary/nocursor'] = {'cursor': o.cursor, 'deleted': o.deleted, 'abstains': o.abstains};
      expect(boundaryViolations(o), contains('cursor null, expected $fixtureExpectedCursor'));
      expect(boundaryViolations(o), contains('cut day $d3 is not labelled deleted'));
      expect(boundaryViolations(o), contains('boundary day $d4 does not abstain'));
    });
  });

  // WHY: primary rows carry the user's choice, while pairing belongs to this install.
  // P2 must repeat these cases against the production mapper's output.
  group('primary wearing adoption through the tagged receiver', () {
    test('fresh unpaired target stashes the choice for pairing', () async {
      await _withFreshTarget((db) async {
        await LocalDb.importFromDbFile('$_dir/policy.db');
        expect(await db.query('device', where: "id = ''"), isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(LocalDb.kPendingWornOnPref), ['', '2', '1']);
        report['wearing/fresh-unpaired'] = prefs.getStringList(LocalDb.kPendingWornOnPref);
      });
    });

    for (final alreadyChosen in [false, true]) {
      test('paired target ${alreadyChosen ? 'keeps its choice' : 'adopts an unset choice'}', () async {
        await _withFreshTarget((db) async {
          await LocalDb.importFromDbFile('$_dir/policy.db');
          final primary = (await db.query('device', where: "id = ''")).single;
          expect(primary['remote_id'], 'target-handle');
          expect(primary['wearing'], alreadyChosen ? 1 : 2);
          expect(primary['wearing_set_ts'], alreadyChosen ? 99 : 1);
          report['wearing/paired/$alreadyChosen'] = primary;
        }, populate: (db) async {
          await LocalDb.upsertDevice(adapterId: 'whoop', remoteId: 'target-handle');
          if (alreadyChosen) {
            await db.update('device', {'wearing': 1, 'wearing_set_ts': 99}, where: "id = ''");
          }
        });
      });
    }
  });

  group('populated target, same-label different-unit custom definition', () {
    test('control: mg stays mg and g history gets its own key', () async {
      final o = await _units('units_control.db');
      report['units/control'] = {'definitions': o.definitions, 'metrics': {for (final e in o.metrics.entries) '${e.key.$1}|${e.key.$2}': e.value}};
      expect(unitViolations(o), isEmpty);
    });

    test('naive copy: the g definition replaces the populated mg one', () async {
      final o = await _units('units_naive.db');
      report['units/naive'] = {'definitions': o.definitions, 'metrics': {for (final e in o.metrics.entries) '${e.key.$1}|${e.key.$2}': e.value}};
      expect(unitViolations(o), contains('$unitKeyCollision is g, the populated target had mg'));
    });
  });
  // Independent values and literal qualified keys; no mapper code is imported
  // into this release package.
  for (final localStamp in [0,1,2]) {
    test('strict edit precedence and whole-date journal set, local stamp $localStamp',() async {
      await _withFreshTarget((db) async {
        await LocalDb.importFromDbFile('$_dir/policy.db');
        final note=(await db.query('journal',where:"date='2026-10-21'")).single;
        expect(note['note'],localStamp<1 ? 'Fork journal':'Local journal');
        final metrics=await db.query('journal_metric',where:"date='2026-10-21'");
        expect(metrics.single['field'],localStamp<1 ? 'custom_u1_637573746f6d5f6361666665696e65_67':'water_ml');
        expect(metrics.single['value'],localStamp<1 ? 0.2:1000.0);
        final labDefs=await db.query('lab_marker_def');
        expect(labDefs.singleWhere((r)=>r['key']=='custom_iron')['unit'],'mg');
        expect(labDefs.singleWhere((r)=>r['key']=='custom_u1_637573746f6d5f69726f6e_67')['unit'],'g');
        expect((await db.query('lab_result',where:"marker='custom_iron'")).single['value'],20.0);
        expect((await db.query('lab_result',where:"marker='custom_u1_637573746f6d5f69726f6e_67'")).single['value'],0.02);
        final race=await HyroxDb.byId(db,'hy-1');
        expect(race,isNotNull);expect(race!.plan,isNotNull);
        expect(race.segments.single.workoutId,'w${dayStartEpoch(6)*1000}');
        expect(race.segments.single.distanceM,900.0);
        expect(EcgReading.fromRow((await db.query('ecg_reading',where:"id='ecg-1'")).single),isNotNull);
        // A later official edit must survive another import of the same file.
        await db.update('journal',{'note':'Later official edit','updated_at':100},where:"date='2026-10-21'");
        await LocalDb.importFromDbFile('$_dir/policy.db');
        expect((await db.query('journal',where:"date='2026-10-21'")).single['note'],'Later official edit');
        report['edits/$localStamp']={'journal':note,'metric_set':metrics,'lab_definitions':labDefs,'race_plan_read':true};
        if(localStamp==0) {
          final exported=await LocalDb.exportCopy(includePrefs:false);
          File(exported).copySync('$_dir/official-return.db');
          report['return_file']='official-return.db';
        }
      },populate:(db) async {
        await db.insert('journal_field_def',{'key':'custom_caffeine','label':'Caffeine','kind':'dose','unit':'mg','max_value':1000.0,'step':10.0,'has_time':0,'created_at':1});
        await db.insert('journal_metric',{'date':'2026-10-22','field':'custom_caffeine','value':200.0,'updated_at':1});
        await db.insert('journal',{'date':'2026-10-21','tags_json':'[]','note':'Local journal','updated_at':localStamp});
        await db.insert('journal_metric',{'date':'2026-10-21','field':'water_ml','value':1000.0,'updated_at':localStamp});
        await db.insert('lab_marker_def',{'key':'custom_iron','label':'Iron','unit':'mg','category':'blood','decimals':1,'created_at':1});
        await db.insert('lab_result',{'marker':'custom_iron','taken_on':'2026-10-22','value':20.0,'unit':'mg','note':'Target lab note','updated_at':2});
      });
    });
  }

  for(final setup in ['defaults','onboarded','populated']) {
    test('portable setting precedence on $setup target',() async {
      await _withFreshTarget((db) async {
        await LocalDb.importFromDbFile('$_dir/policy.db');
        final prefs=await SharedPreferences.getInstance();
        expect(prefs.getString('clock_format'),setup=='defaults' ? '24h':'12h');
        report['settings/$setup']={'clock_format':prefs.getString('clock_format')};
      },populate:(db) async {
        final prefs=await SharedPreferences.getInstance();
        await prefs.setString('clock_format',setup=='defaults' ? 'system':'12h');
        if(setup=='onboarded') {await prefs.setBool('onboard.completed',true);}
        if(setup=='populated') {await db.insert('journal',{'date':'2001-01-01','note':'own data','tags_json':'[]','updated_at':1});}
      });
    });
  }

}
