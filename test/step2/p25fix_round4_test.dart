// P2.5 fix round 4 (owner-approved scope).
//
//   * Legacy wake_day_features rows are NOT backfilled into row_rev (the
//     backfill needed window functions, SQLite 3.25; minSdk 26 ships 3.18).
//     Such a row has no revision, is served correctly, is never cached, and
//     gains a revision when it is rewritten. The SQL-floor guard itself is
//     test/guards/sqlite_floor_guard_test.dart.
//   * AppState._maybeNotifyRecoveryReady says nothing when the store was wiped
//     while it awaited the day's sleep block.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/json_payload_lane.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/app_state.dart';

import '../support/app_state_derive_harness.dart' as harness;
import 'support/p25_support.dart';

const _name = 'p25fix_round4.db';

class _CountingLane implements JsonPayloadDecodeLane {
  int calls = 0;
  @override
  Future<JsonPayloadsResult> run(JsonPayloadsInput input) async {
    calls++;
    return decodeJsonPayloadsHeavy(bundleWorkerInputs, input);
  }
}

/// Wipes the store while the recovery note awaits the day's sleep block.
class _WipingRepo extends harness.RescoreRepo {
  int blockReads = 0;
  @override
  Future<Map<String, dynamic>> getDayBlock(String day, List<String> keys) async {
    blockReads++;
    await LocalDb.wipeAll();
    return {
      'sleep': {
        'accounting': {'value': {'tst_sec': 27000}},
      },
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    JsonPayloadLane.debugResetShared();
    await p21Drop(_name);
  });

  group('a legacy wake row (no row_rev)', () {
    final day = p23Day(0);

    Future<void> legacyRow() async {
      await p25Wake(db, day, {'steps': 4100.0});
      // As written before the revision triggers existed.
      await db.delete('row_rev',
          where: "kind = 'wake_day_features' AND k1 = ?", whereArgs: [day]);
    }

    Future<int?> revOf() async =>
        (await LocalDb.wakeDayFeatures(day, p21Version))?['rev'] as int?;

    test('has no revision, and opening the store again does not invent one',
        () async {
      await legacyRow();
      expect(await revOf(), isNull);

      await p21Reopen(); // _repairOpenSchema runs on every open

      expect(await revOf(), isNull, reason: 'no backfill');
      final rows = await (await LocalDb.instance).query('row_rev',
          where: "kind = 'wake_day_features'");
      expect(rows, isEmpty);
    });

    test('is served correctly, is NOT cached, and is cached once rewritten',
        () async {
      await legacyRow();
      final counting = _CountingLane();
      final lane = JsonPayloadLane(lane: counting);
      final source = WakeFeaturesRowSource(day, p21Version);

      final row = (await LocalDb.wakeDayFeatures(day, p21Version))!;
      final first = await lane.decode(source, WakeFeaturesRowSource.stateOf(row));
      final second = await lane.decode(source, WakeFeaturesRowSource.stateOf(row));

      expect((first!.value as Map)['steps'], 4100.0);
      expect((second!.value as Map)['steps'], 4100.0);
      expect(counting.calls, 2, reason: 'a revision-less row is never a cache hit');
      expect(lane.debugEntries, 0);

      await LocalDb.putWakeDayFeatures(
          dayId: day, algoVersion: p21Version, payloadJson: '{"steps":4200.0}');
      expect(await revOf(), isNotNull, reason: 'it gains a revision when written');
      final fresh = (await LocalDb.wakeDayFeatures(day, p21Version))!;
      final third = await lane.decode(source, WakeFeaturesRowSource.stateOf(fresh));
      final fourth = await lane.decode(source, WakeFeaturesRowSource.stateOf(fresh));

      expect((third!.value as Map)['steps'], 4200.0);
      expect((fourth!.value as Map)['steps'], 4200.0);
      expect(counting.calls, 3, reason: 'now the second read is a hit');
      expect(lane.debugEntries, 1);
    });
  });

  group('recovery-ready note across a wipe', () {
    late List<NotificationEvent> shown;
    late Future<bool> Function(NotificationEvent, {bool allowPermissionPrompt}) realSink;

    setUp(() {
      shown = [];
      realSink = NotificationCenter.instance.presentSink;
      NotificationCenter.instance.presentSink = (e, {bool allowPermissionPrompt = true}) async {
        shown.add(e);
        return true;
      };
      addTearDown(() => NotificationCenter.instance.presentSink = realSink);
      SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    });

    Future<AppState> app() async {
      await p25Row(db, p23Day(0), payload: '{"scalars":{"steps":4000}}', readiness: 77.4, computedAt: 7000);
      final a = AppState.forTesting();
      addTearDown(a.dispose);
      a.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      a.debugDeriveRun = harness.deriveHook(days: [p23Day(0)]);
      return a;
    }

    test('control: without a wipe the note fires', () async {
      final a = await app();

      await a.debugRunScheduled(kind: DeriveJobKind.heavy);
      await harness.until(() => shown.isNotEmpty, what: 'the recovery note');

      expect(shown.single.body, 'Recovery 77.');
    });

    test('a wipe during the getDayBlock read: no notification, no claim',
        () async {
      final a = await app();
      final repo = _WipingRepo();
      a.repo = repo;

      await a.debugRunScheduled(kind: DeriveJobKind.heavy);
      await harness.until(() => repo.blockReads > 0, what: 'the block read');
      await harness.settleMs(400);

      expect(repo.blockReads, 1, reason: 'guard: the wipe happened mid-read');
      expect(shown, isEmpty);
      expect((await SharedPreferences.getInstance()).getString('last_recovery_notif_day'),
          isNull);
    });
  });
}
