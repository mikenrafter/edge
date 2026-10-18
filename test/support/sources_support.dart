// Shared seams and fixtures for the sources tests.
//
// Everything here either compiles against code that exists today or reaches a
// not-yet-written production seam by DYNAMIC invocation, so a missing seam
// fails with a message naming the contract in docs/sources-data-shapes.md
// instead of a compile error. Nothing here supplies source-resolution policy:
// owners, reasons, agreement, identity suffixes and consequence text all come
// from production objects.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

const kContractDoc = 'docs/sources-data-shapes.md';

/// Lets a test reach a production seam that may not exist, failing with a clear message.
T sourcesContract<T>(String behavior, T Function() invoke) {
  try {
    return invoke();
  } on NoSuchMethodError {
    fail('Missing production behavior: $behavior. See $kContractDoc.');
  }
}

Future<T> sourcesAsync<T>(String behavior, Future<T> Function() invoke) async {
  try {
    return await invoke();
  } on NoSuchMethodError {
    fail('Missing production behavior: $behavior. See $kContractDoc.');
  }
}

// ── sources used by every fixture ───────────────────────────────────────────

const kPrimary = LocalDb.kPrimaryDeviceId; // ''
const kStrapA = 'ble_hrs-0a1b2c3d';
const kStrapB = 'ble_hrs-9f8e7d6c';
const kRing = 'ring-TEST-0001';
const kRemoteA = 'AA:BB:CC:DD:EE:01';
const kRemoteB = 'AA:BB:CC:DD:EE:02';

const kBand = HealthSource(
  name: 'WHOOP',
  kind: 'WHOOP 4 · wrist optical',
  tier: SourceTier.wristOptical,
  icon: Icons.watch,
  isBand: true,
  family: 'gen4',
);

HealthSource strap(String id, {String name = 'Polar H10'}) => HealthSource(
  name: name,
  kind: 'Bluetooth heart rate sensor',
  tier: SourceTier.beatToBeat,
  icon: Icons.favorite,
  deviceId: id,
  family: 'ble_hrs',
);

const kRingSource = HealthSource(
  name: 'Test ring',
  kind: 'ring',
  tier: SourceTier.wristOptical,
  icon: Icons.circle,
  deviceId: kRing,
  family: 'gen5',
);

const kPhone = HealthSource(
  name: 'This phone',
  kind: 'Motion coprocessor',
  tier: SourceTier.phone,
  icon: Icons.phone_android,
);

// ── time and database helpers ───────────────────────────────────────────────

int sec(int y, int mo, int d, int h, [int mi = 0]) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

/// Opens a fresh real LocalDb (the coverage_devices_by_day_test idiom).
void useSourcesDb(String name) {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = name;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance; // run the ladder once.
  });
  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
}

Future<void> insertCoverage(
  String deviceId,
  InputSignal signal,
  int start,
  int end,
) async {
  final db = await LocalDb.instance;
  await db.insert('device_coverage', {
    'device_id': deviceId,
    'signal': signal.name,
    'start_ts': start,
    'end_ts': end,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// Constant-heart-rate 1 Hz-table rows (10 s step: mechanical, not staging).
Future<void> insertOneHz(
  String deviceId,
  int from,
  int to,
  int hr, {
  int step = 10,
}) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  var counter = 0;
  for (var ts = from; ts < to; ts += step) {
    batch.insert('decoded_onehz', {
      'device_id': deviceId,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': counter++,
      'hr': hr,
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

Future<void> insertDeviceRow(String id, String remoteId, String label) =>
    LocalDb.upsertDevice(
      id: id,
      adapterId: 'ble_hrs',
      remoteId: remoteId,
      label: label,
      tier: 'beatToBeat',
    );

// ── production seams (dynamic, see sources_contract.md) ─────────────────────

/// AppState.debugSourceService(sources:, now:) -> production SourceService.
dynamic openService({
  required List<HealthSource> sources,
  DateTime Function()? now,
}) {
  final dynamic app = AppState.forTesting();
  return sourcesContract(
    'AppState.debugSourceService(sources:, now:) returning the production '
    'SourceService',
    () => app.debugSourceService(
      sources: sources,
      now: now ?? () => DateTime(2026, 9, 30, 12),
    ),
  );
}

/// AppState.debugSourceViews() -> production pure-view factory.
dynamic openViews() {
  final dynamic app = AppState.forTesting();
  return sourcesContract(
    'AppState.debugSourceViews() returning the production SourceViews factory',
    () => app.debugSourceViews(),
  );
}

Map<String, Object?> jsonOf(dynamic object, String what) => sourcesContract(
  '$what.toJson()',
  () => Map<String, Object?>.from(object.toJson() as Map),
);

void requireKeys(Map<String, Object?> json, Iterable<String> keys, String what) {
  final missing = [for (final k in keys) if (!json.containsKey(k)) k];
  if (missing.isNotEmpty) {
    fail('Missing contract field(s) on $what: $missing. See $kContractDoc.');
  }
}

const kCardKeys = [
  'deviceId',
  'name',
  'displayLabel',
  'type',
  'model',
  'platformIdSuffix',
  'identitySuffix',
  'signals',
  'supplies',
  'collection',
  'coverage',
  'lastSeen',
  'permissions',
  'limitations',
  'uses',
];

const kIntervalKeys = [
  'signal',
  'start',
  'end',
  'kind',
  'winner',
  'alternatives',
  'agreement',
  'reasonCode',
  'reason',
  'values',
];

Future<List<Map<String, Object?>>> cardsOf(dynamic svc) async {
  final list = await sourcesAsync<dynamic>(
    'SourceService.cards() returning the source catalog card models',
    () async => await svc.cards(),
  );
  return [
    for (final c in list as List)
      () {
        final j = jsonOf(c, 'SourceCard');
        requireKeys(j, kCardKeys, 'SourceCard');
        return j;
      }(),
  ];
}

Map<String, Object?> cardFor(List<Map<String, Object?>> cards, String id) =>
    cards.firstWhere(
      (c) => c['deviceId'] == id,
      orElse: () => fail('No catalog card for device "$id".'),
    );

Future<List<Map<String, Object?>>> resolveJson(
  dynamic svc,
  InputSignal signal,
  int from,
  int to,
) async {
  final list = await sourcesAsync<dynamic>(
    'SourceService.resolve(signal:, from:, to:) returning resolved intervals',
    () async => await svc.resolve(signal: signal, from: from, to: to),
  );
  return [
    for (final i in list as List)
      () {
        final j = jsonOf(i, 'ResolvedInterval');
        requireKeys(j, kIntervalKeys, 'ResolvedInterval');
        return j;
      }(),
  ];
}

/// The interval containing [ts] (start inclusive, end exclusive).
Map<String, Object?> at(List<Map<String, Object?>> intervals, int ts) =>
    intervals.firstWhere(
      (i) => (i['start'] as int) <= ts && ts < (i['end'] as int),
      orElse: () => fail('No resolved interval covers $ts.'),
    );

/// Intervals must tile [from, to) with no hole and no overlap.
void expectTiles(List<Map<String, Object?>> intervals, int from, int to) {
  expect(intervals, isNotEmpty);
  expect(intervals.first['start'], from, reason: 'first interval starts at from');
  expect(intervals.last['end'], to, reason: 'last interval ends at to');
  for (var i = 1; i < intervals.length; i++) {
    expect(
      intervals[i]['start'],
      intervals[i - 1]['end'],
      reason: 'intervals tile the window with no hole or overlap',
    );
  }
}

// ── widget helpers ──────────────────────────────────────────────────────────

Finder textLike(Pattern pattern) => find.byWidgetPredicate((w) {
  if (w is! Text) return false;
  final s = (w.data ?? w.textSpan?.toPlainText() ?? '').toLowerCase();
  return pattern is RegExp ? pattern.hasMatch(s) : s.contains(pattern.toString().toLowerCase());
});

Widget material(Widget child, {Brightness brightness = Brightness.light, double scale = 1}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness),
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: c!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

// ── JSON fixtures for the pure views ────────────────────────────────────────

Map<String, Object?> cardFixture({
  String deviceId = kStrapA,
  String name = 'Polar H10',
  String? suffix = '2c3d',
  String type = 'sensor',
  String? model = 'Bluetooth heart rate sensor',
  String? platformIdSuffix = 'EE01',
  String collection = 'user-started',
  Map<String, Object?>? coverage,
  int? lastSeen,
  List<String> signals = const ['hrSparse', 'rrIntervals'],
  List<String> permissions = const ['bluetooth'],
  List<String> limitations = const ['Experimental: nobody on the project has held one.'],
  List<Map<String, Object?>> uses = const [
    {
      'signal': 'rrIntervals',
      'reasonCode': 'userPriority',
      'reason': 'First in your order for beat timing.',
    },
  ],
}) => {
  'deviceId': deviceId,
  'name': name,
  'displayLabel': suffix == null ? name : '$name · $suffix',
  'type': type,
  'model': model,
  'platformIdSuffix': platformIdSuffix,
  'identitySuffix': suffix,
  'signals': signals,
  'supplies': const <String>[],
  'collection': collection,
  'coverage': coverage,
  'lastSeen': lastSeen,
  'permissions': permissions,
  'limitations': limitations,
  'uses': uses,
};

Map<String, Object?> intervalFixture({
  String signal = 'rrIntervals',
  required int start,
  required int end,
  String kind = 'overlap',
  String? winner = kStrapA,
  List<String> alternatives = const [kPrimary],
  String agreement = 'agree',
  String reasonCode = 'userPriority',
  String reason = 'Ranked first in your order for beat timing.',
  Map<String, Object?> values = const {},
}) => {
  'signal': signal,
  'start': start,
  'end': end,
  'kind': kind,
  'winner': winner,
  'alternatives': alternatives,
  'agreement': agreement,
  'reasonCode': reasonCode,
  'reason': reason,
  'values': values,
};

const kFixtureNames = {
  kPrimary: 'WHOOP',
  kStrapA: 'Polar H10 · 2c3d',
};

/// Writes a deterministic machine-readable artifact next to build/.
void writeArtifact(String name, Object json) {
  final dir = Platform.environment['EDGE_PROOF_DIR'] ?? 'build/sources';
  final file = File('$dir/$name');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}
