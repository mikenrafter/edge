// Guard (phase 1; passes today and must keep passing): a WEARABLE day (a Colmi
// ring as the active wearable, no band rows) never streams RR in a warm
// process. Two passes on one engine report neither `day_rr_beats_folded` nor
// `day_rr_batch_runs` above 0, and the stored day equals a cold forced derive.
// See test/day_rr_warm_stream_test.dart for the band-day work pins.

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
const String _id = 'colmi-warm';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);

int _count(DerivationEngine e, String name) =>
    ((e.perf.summary()['counts'] as Map)[name] as num?)?.toInt() ?? 0;

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
    LocalDb.dbName = 'day_rr_warm_wearable_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _id, adapterId: 'colmi', remoteId: 'AA:BB:CC:00:00:08', label: _id);
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

  test('two warm passes on a wearable day never stream, and match a cold derive',
      () async {
    final warm = DerivationEngine();
    await warm.runDays(_profile, {_dayId}, force: true);
    expect(await LocalDb.dayResult(_dayId), isNotNull, reason: 'fixture');
    for (var pass = 1; pass <= 2; pass++) {
      if (pass == 2) await warm.runDays(_profile, {_dayId});
      expect(_count(warm, 'day_rr_beats_folded'), 0, reason: 'pass $pass');
      expect(_count(warm, 'day_rr_batch_runs'), 0, reason: 'pass $pass');
    }
    final got = await _stored();
    await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    expect(await _stored(), got);
  });
}
