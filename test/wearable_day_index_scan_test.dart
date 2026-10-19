// A derive pass on a wearable install scans the wearable's per-day index
// (every retained row) at most ONCE, and a pass after the readiness
// calibration backfill is done never builds substrateDays for it. The stored
// day still equals a cold derive.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
const String _dayId = '2026-10-04';
const String _id = 'colmi-scan';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);

Future<String> _stored() async {
  final row = (await LocalDb.dayResult(_dayId))!;
  final payload = jsonDecode(row['payload_json'] as String) as Map;
  payload.remove('computed_at');
  return jsonEncode(payload);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'wearable_day_index_scan_test.db';
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
  });

  tearDownAll(() async {
    onWearableDaysChanged = null;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('one wearable day-index scan per pass; none for a finished backfill',
      () async {
    final warm = DerivationEngine();
    // Pass 1 may run the backfill to completion.
    await warm.run(_profile, force: true);
    await warm.run(_profile, force: true);
    expect(await LocalDb.dayResult(_dayId), isNotNull, reason: 'fixture');

    debugWearableDayIndexScans = 0;
    debugSubstrateDaysCalls = 0;
    await warm.run(_profile, force: true);
    expect(debugWearableDayIndexScans, lessThanOrEqualTo(1));
    expect(debugSubstrateDaysCalls, 0,
        reason: 'backfill is done: its day set is never built');

    final got = await _stored();
    await DerivationEngine().run(_profile, force: true);
    expect(await _stored(), got);
  });
}
