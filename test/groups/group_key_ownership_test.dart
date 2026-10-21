// Design 06 phase 1a: every top-level day-bundle key and every metric_series
// key a real derive writes has exactly one owning group; the ownership maps
// name no key no derive could produce.
//
// The expected key sets come from real derives, never a hand list:
//  - a pure band-shaped day through deriveDayBundle (test/support/
//    incremental_day_fixture.dart), and
//  - a wearable day through DerivationEngine.runDays into LocalDb, reading
//    back the stored day_result payload and the metric_series rows
//    (the same setup as test/day_rr_warm_wearable_test.dart).
// Their union is what "a derive produces". Keys that only appear under a
// condition these fixtures don't meet go in kConditionalKeys, with a reason.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/groups/edge_groups.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/incremental_day_fixture.dart';
import '../support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
const String _dayId = '2026-10-04';
const String _id = 'colmi-groups';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);

final Set<String> _bundleKeys = {};
final Set<String> _seriesKeys = {};
final Set<String> _nestedKeys = {};

void _collectNested(Map bundle) {
  for (final b in kMixedBlocks) {
    final v = bundle[b];
    if (v is Map) _nestedKeys.addAll(v.keys.map((k) => '$b.$k'));
  }
}

void main() {
  setUpAll(() async {
    // 1. Pure derive on the band-shaped incremental day.
    final pure = deriveDayBundle(incrementalDay());
    _bundleKeys.addAll(pure.keys);
    _collectNested(pure);

    // 2. Real engine derive into a database.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'group_key_ownership_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _id, adapterId: 'colmi', remoteId: 'AA:BB:CC:00:00:09', label: _id);
    await ColmiLink.instance.ingestForTest(
        _id,
        (_, w) => w[0] == kColmiCmdBigData && w[1] == kColmiBigSleep
            ? [colmiBigDataRequest(kColmiBigSleep, [0])]
            : SyntheticDay.colmiRingReply(_days, w, _now),
        nowSeconds: () => SyntheticDay.sec(_now));
    await LocalDb.setCursor(kActiveWearableCursor, _id);
    await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');
    await DerivationEngine().runDays(_profile, {_dayId}, force: true);

    final row = (await LocalDb.dayResult(_dayId))!;
    final stored = jsonDecode(row['payload_json'] as String) as Map;
    _bundleKeys.addAll(stored.keys.cast());
    _collectNested(stored);
    final db = await LocalDb.instance;
    for (final r in await db.query('metric_series', columns: ['key'])) {
      _seriesKeys.add(r['key'] as String);
    }
  });

  tearDownAll(() async {
    onWearableDaysChanged = null;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final groupIds = {
    for (final g in kMergedRegistry.groups) g.id
  };

  test('the real derives produced keys (the fixture is not vacuous)', () {
    expect(_bundleKeys, isNotEmpty);
    expect(_seriesKeys, isNotEmpty);
  });

  test('every bundle key a derive wrote has an owner', () {
    final orphans = _bundleKeys.difference(kBundleKeyOwner.keys.toSet());
    expect(orphans, isEmpty,
        reason: 'unowned top-level bundle keys: ${orphans.toList()..sort()}');
  });

  test('every metric_series key a derive wrote has an owner', () {
    final orphans = _seriesKeys.difference(kSeriesKeyOwner.keys.toSet());
    expect(orphans, isEmpty,
        reason: 'unowned metric_series keys: ${orphans.toList()..sort()}');
  });

  test('every owner names a declared group', () {
    final bad = {
      for (final e in {
        ...kBundleKeyOwner,
        ...kSeriesKeyOwner,
        ...kNestedKeyOwner
      }.entries)
        if (!groupIds.contains(e.value)) '${e.key} -> ${e.value}'
    };
    expect(bad, isEmpty);
  });

  test('the ownership maps name no key a derive could not produce', () {
    final allowed = {..._bundleKeys, ...kConditionalKeys.keys};
    final phantom = kBundleKeyOwner.keys.toSet().difference(allowed);
    expect(phantom, isEmpty, reason: 'phantom bundle keys: $phantom');
    final allowedSeries = {..._seriesKeys, ...kConditionalKeys.keys};
    final phantomSeries = kSeriesKeyOwner.keys.toSet().difference(allowedSeries);
    expect(phantomSeries, isEmpty, reason: 'phantom series keys: $phantomSeries');
  });

  test('every conditional key states its condition', () {
    for (final e in kConditionalKeys.entries) {
      expect(e.value.trim(), isNotEmpty, reason: e.key);
    }
  });

  test('the merged edge + analytics registry validates', () {
    expect(validateRegistry(kMergedRegistry), isEmpty);
  });

  group('mixed blocks (series / clinical / scalars)', () {
    test('every nested key a derive wrote has its own owner', () {
      final orphans = _nestedKeys.difference(kNestedKeyOwner.keys.toSet());
      expect(orphans, isEmpty,
          reason: 'unowned nested keys: ${orphans.toList()..sort()}');
    });

    test('the nested owners name no key a derive could not produce', () {
      final allowed = {..._nestedKeys, ...kConditionalKeys.keys};
      final phantom = kNestedKeyOwner.keys.toSet().difference(allowed);
      expect(phantom, isEmpty, reason: 'phantom nested keys: $phantom');
    });

    test('each mixed block is assembled by edge.assembly, which depends on '
        'every group that writes into it', () {
      for (final b in kMixedBlocks) {
        expect(kBundleKeyOwner[b], 'edge.assembly', reason: b);
      }
      final upstream = {
        'edge.assembly',
        ...transitiveDeps(kMergedRegistry, 'edge.assembly')
      };
      final missing = {
        for (final e in kNestedKeyOwner.entries)
          if (!upstream.contains(e.value)) '${e.key} -> ${e.value}'
      };
      expect(missing, isEmpty);
    });

    test('a nested scalar has the same owner as its metric_series row', () {
      final split = <String>[
        for (final e in kNestedKeyOwner.entries)
          if (e.key.startsWith('scalars.') &&
              kSeriesKeyOwner[e.key.substring(8)] != null &&
              kSeriesKeyOwner[e.key.substring(8)] != e.value)
            '${e.key}: ${e.value} vs ${kSeriesKeyOwner[e.key.substring(8)]}'
      ];
      expect(split, isEmpty);
    });
  });

  group('producers', () {
    // function name -> owning group id, over the merged registry.
    final byFn = <String, String>{
      for (final g in kMergedRegistry.groups)
        for (final f in [...g.members, ...g.api]) f: g.id
    };
    String ownerOf(String key) =>
        kNestedKeyOwner[key] ?? kBundleKeyOwner[key] ?? '?';
    final keys = {...kNestedKeyOwner.keys, 'wrist_orientation'};

    test('every owned nested key, and wrist_orientation, lists producers', () {
      expect(kKeyProducers.keys.toSet(), keys);
      for (final e in kKeyProducers.entries) {
        expect(e.value, isNotEmpty, reason: e.key);
      }
    });

    test('each producer is registered and sits in the owner or its deps', () {
      final bad = <String>[];
      for (final e in kKeyProducers.entries) {
        final owner = ownerOf(e.key);
        final allowed = {owner, ...transitiveDeps(kMergedRegistry, owner)};
        for (final fn in e.value) {
          final g = byFn[fn];
          if (g == null) {
            bad.add('${e.key}: $fn is in no group');
          } else if (!allowed.contains(g)) {
            bad.add('${e.key} (owner $owner): $fn is in $g, not a dependency');
          }
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('each producer has a call site under lib/compute', () {
      final src = StringBuffer();
      for (final f in Directory('lib/compute')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        src.writeln(f
            .readAsStringSync()
            .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
            .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), ''));
      }
      final text = src.toString();
      final missing = <String>{
        for (final fn in kKeyProducers.values.expand((v) => v))
          if (!RegExp(fn.contains('.')
                  ? '\\b${fn.split('.').first}\\s*\\.\\s*${fn.split('.').last}\\s*[(<]'
                  : '(?<![\\w\$])$fn\\s*[(<]')
              .hasMatch(text))
            fn
      };
      expect(missing, isEmpty, reason: 'no call site: $missing');
    });
  });
}
