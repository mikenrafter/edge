// Restore precedence for the two HMM staging keys (fix round 3, F2): either key
// in a backup lands in `sleep_hmm_stages`; the older key is never written; when
// a backup carries both `sleep_hmm_stages=false` and
// `compute.experimental_sleep_hmm=true`, restore resolves the incoming pair the
// same way in-place upgrade does (keeping the legacy opt-in) before writing
// prefs, while preserving non-fresh install protection for existing local prefs.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/import_focus.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/sleep_writes.dart';
import 'backup_support.dart';

const _start = 1782532800; // 2026-06-27 04:00 UTC
const _day = '2026-06-27';

Future<void> _seedNight(int seconds) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var i = 0; i < seconds; i++) {
    final ts = _start + i;
    batch.insert('decoded_onehz', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': i,
      'hr': 60,
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
      'device_family': 'gen4',
    });
    batch.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'beat_index': 0,
      'rr_ts_ms': ts * 1000,
      'rr_ms': i.isEven ? 1000 : 1100,
      'device_family': 'gen4',
    });
  }
  await batch.commit(noResult: true);
  await TestSleepWrites.putSleepOverride(
    dayId: _day,
    onsetTs: _start,
    offsetTs: _start + seconds,
    source: 'manual',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
    env = await BackupEnv.create('bkx_hmm_choice_test.db');
    await Prefs.ensureLoaded();
  });
  tearDown(() {
    WorkerInit.resetForTest();
    ImportFocus.debugReset();
  });
  tearDownAll(() async => env.dispose());

  Future<String> exportWithPrefs(Map<String, Object> prefs) async {
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await setPrefs(prefs);
    return LocalDb.exportCopy();
  }

  Future<Map<String, Object>> restore(Map<String, Object> prefs) async {
    final path = await exportWithPrefs(prefs);
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await LocalDb.importFromDbFile(path);
    return allPrefs();
  }

  test('the older key alone restores into sleep_hmm_stages', () async {
    final now = await restore({'compute.experimental_sleep_hmm': true});
    expect(now['sleep_hmm_stages'], true);
    expect(now.containsKey('compute.experimental_sleep_hmm'), isFalse);
  });

  // why: review r2 F2 (settled). On a pre-merge fork install, Settings only
  // wrote compute.experimental_sleep_hmm; restore must agree with in-place
  // upgrade (readSleepHmmChoice) and preserve the legacy opt-in regardless of
  // row order in backup_prefs.
  // # catches: letting sleep_hmm_stages=false win or writing in row order.
  test('conflicting pair keeps legacy opt-in, matching in-place upgrade',
      () async {
    final path = await exportWithPrefs({
      'sleep_hmm_stages': false,
      'compute.experimental_sleep_hmm': true,
    });
    // Also verify row order with sleep_hmm_stages stored first in backup_prefs.
    final copy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await copy.delete('backup_prefs');
    await copy.insert('backup_prefs',
        {'key': 'sleep_hmm_stages', 'type': 'bool', 'value': 'false'});
    await copy.insert('backup_prefs', {
      'key': 'compute.experimental_sleep_hmm',
      'type': 'bool',
      'value': 'true',
    });
    await copy.close();

    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now['sleep_hmm_stages'], true);
    expect(now.containsKey('compute.experimental_sleep_hmm'), isFalse);
  });

  // why: review r2 F2. Resolving the incoming pair before writing must keep
  // existing non-fresh install protection when sleep_hmm_stages is already set
  // locally, and still write true when it is absent locally.
  // # catches: overwriting local prefs on non-fresh install, or self-blocking
  //   by writing sleep_hmm_stages=false before reading the legacy key.
  test('non-fresh install keeps an existing local choice and resolves when absent',
      () async {
    final path = await exportWithPrefs({
      'sleep_hmm_stages': false,
      'compute.experimental_sleep_hmm': true,
    });

    // Non-fresh with existing local opt-out: local false is preserved.
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await env.seedData(t0: 1790100000);
    await setPrefs({'sleep_hmm_stages': false});
    expect(await isFreshInstall(), isFalse);
    final keptSummary = await LocalDb.importFromDbFile(path);
    final keptPrefs = await allPrefs();
    expect(keptPrefs['sleep_hmm_stages'], false,
        reason: 'existing local pref on a non-fresh install must not be overwritten');
    expect(keptPrefs.containsKey('compute.experimental_sleep_hmm'), isFalse);
    expect(keptSummary.prefsKept, greaterThanOrEqualTo(1));

    // Non-fresh with sleep_hmm_stages absent locally: incoming pair resolves to true.
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await env.seedData(t0: 1790100000);
    expect(await isFreshInstall(), isFalse);
    await LocalDb.importFromDbFile(path);
    final restoredPrefs = await allPrefs();
    expect(restoredPrefs['sleep_hmm_stages'], true,
        reason: 'resolving before writing avoids blocking the legacy opt-in');
    expect(restoredPrefs.containsKey('compute.experimental_sleep_hmm'), isFalse);
  });

  // why: review r2 F2. End-to-end check across restore -> Settings hydration
  // (AppState) -> real derivation -> repository read for the conflicting pair.
  // # catches: any mismatch between backup restore, AppState hydration,
  //   DerivationEngine pref read, and LocalRepositoryImpl provenance output.
  test('conflicting backup pair flows through restore, AppState hydration, '
      'real derivation and repository read as upstream HMM staging', () async {
    final path = await exportWithPrefs({
      'sleep_hmm_stages': false,
      'compute.experimental_sleep_hmm': true,
    });

    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await Prefs.reload();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;

    await app.importEdgeBackup(path);

    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    expect(sp.getBool('sleep_hmm_stages'), isTrue,
        reason: 'canonical choice must be true after restoring the conflicting pair');
    expect(sp.containsKey('compute.experimental_sleep_hmm'), isFalse,
        reason: 'legacy key must be absent after restore');
    expect(app.sleepHmmStagesEnabled, isTrue,
        reason: 'Settings hydration in AppState must reflect the restored opt-in');

    await _seedNight(5400);
    expect(
      await DerivationEngine().runDays(const Profile(ageYears: 35), {_day}, force: true),
      1,
    );
    // The real derivation above stands in for the queued post-import pass, so
    // leave ImportFocus before reading through LocalRepositoryImpl.
    ImportFocus.leave();
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final night = await repo.getDaySleepV2(_day);
    expect(night['staging_method'], 'hmm',
        reason: 'repository must expose upstream HMM staging for the derived night');
    expect(night['staging_effective_method'], isNot('hmm628'));
  });

  test('the upstream key alone restores as it is', () async {
    final now = await restore({'sleep_hmm_stages': true});
    expect(now['sleep_hmm_stages'], true);
    final off = await restore({'sleep_hmm_stages': false});
    expect(off['sleep_hmm_stages'], false);
  });
}
