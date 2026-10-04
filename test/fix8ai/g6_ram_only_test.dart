// 8AI G6 / AGENTS.md §3.14: live high-rate streams (0x28 / 0x2B / 0x33) are
// RAM only. Starting the feed, receiving a flood of frames and stopping it
// must not write a single row anywhere.
//
// Measured with SQLite's `total_changes()` on the app's own connection: it
// counts every INSERT / UPDATE / DELETE (incl. REPLACE and trigger/cascade
// work) since the connection opened, so a write into ANY table — decoded_onehz,
// raw_records, raw_archive, a settings/kv row, a "last live" bookmark —
// moves it. Row counts alone would miss an UPDATE.
//
// Test 1 is a guard on today's behaviour (frames alone). Test 2 needs the new
// AppState.startLiveFeed / stopLiveFeed (see g6_start_stop_commands_test.dart)
// and pins that the control itself persists nothing (e.g. no "feed was on"
// preference that would re-arm streaming after a restart).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show BandProfile;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/g6_support.dart';

const _dbName = 'g6_ram_only_test.db';

Future<int> _totalChanges() async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT total_changes() AS n');
  return (r.single['n'] as num).toInt();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = _dbName;
    await databaseFactory
        .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), _dbName));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory
        .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), _dbName));
  });

  Future<void> flood(G6Rig rig) async {
    for (var i = 0; i < 5; i++) {
      rig.feed(hr28Inner(hr: 60 + i, rr: [800 + i], ts: nowSec() + i));
      rig.feed(r21LiveInner());
      rig.feed(r17LiveInner());
    }
  }

  test('guard: live frames alone write nothing', () async {
    final rig = G6Rig();
    addTearDown(rig.dispose);
    await LocalDb.instance; // open + migrate before the baseline
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final before = await _totalChanges();
    await flood(rig);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await _totalChanges(), before);
    expect(rig.app.liveStreams.streamKeys(kBandId), isNotEmpty,
        reason: 'the frames did land in RAM');
  });

  for (final gen5 in [true, false]) {
    test('start -> frames -> stop persists nothing (${gen5 ? 'gen5' : 'gen4'})',
        () async {
      final rig = G6Rig(band: gen5 ? BandProfile.gen5 : BandProfile.gen4);
      addTearDown(rig.dispose);
      await LocalDb.instance;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = await _totalChanges();
      await startFeed(rig.app);
      await rig.settle();
      await flood(rig);
      await stopFeed(rig.app);
      await rig.settle();
      expect(await _totalChanges(), before,
          reason: 'no row written by the feed, its frames, or its Stop');
    });
  }
}
