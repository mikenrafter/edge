// P4c: what recordings a stored day result covers.
//
// ASSUMED API:
//   LocalRepository.dayRecordingsThrough(String day) -> Future<DateTime?>
//       Default null (a fake that does not override it knows nothing).
//   LocalRepositoryImpl.dayRecordingsThrough(day): the MAX(rec_ts) part of the
//       `derived_fp:<day>` fingerprint ("MAX(rec_ts):COUNT(*):REVSUM", written
//       by LocalDb.putDerivedFingerprint after each derived day), as a local
//       DateTime from epoch SECONDS. Null when:
//         * the day has no fingerprint row,
//         * the row was written under another algo version (it describes a
//           result this build does not serve),
//         * the row or its first part does not parse.
//       A legacy two-part "MAX:COUNT" fingerprint still yields its MAX.
//       One keyed read of one row; it never reads or decodes a day_result
//       payload and never reads another day's fingerprint.
//
// Failure mode today: the method does not exist (NoSuchMethodError).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show deriveFingerprint, kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support/last_result_db.dart';
import 'support/as_of_recalc_fakes.dart' show HomeRepo, homeBundle;

const _db = 'p4c_day_recordings_through_test.db';

// 2026-10-03 08:36:00 local, as epoch seconds.
final _sec = DateTime(2026, 10, 3, 8, 36).millisecondsSinceEpoch ~/ 1000;

Future<DateTime?> _through(LocalRepositoryImpl r, String day) async =>
    await (r as dynamic).dayRecordingsThrough(day) as DateTime?;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await g1FreshDb(_db);
    await LocalDb.instance;
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
  });
  tearDownAll(() => g1DropDb(_db));

  test('the fingerprint\'s MAX(rec_ts), as a local time', () async {
    await LocalDb.putDerivedFingerprint('2026-10-03', kAlgoVersion, '$_sec:120:7');
    final at = await _through(repo, '2026-10-03');
    expect(at, DateTime.fromMillisecondsSinceEpoch(_sec * 1000));
    expect(at!.isUtc, isFalse, reason: 'shown on the local clock (§3.7)');
  });

  test('the engine fingerprint exposes its own day MAX through the reader',
      () async {
    final fingerprint = deriveFingerprint(
      profileSig: '{"name":"a|b"}',
      own: '$_sec:120:7',
      previous: '${_sec - 86400}:120:6',
    )!;
    await LocalDb.putDerivedFingerprint('2026-10-03', kAlgoVersion, fingerprint);

    expect(await _through(repo, '2026-10-03'),
        DateTime.fromMillisecondsSinceEpoch(_sec * 1000));
  });

  test('a legacy two-part fingerprint still gives its MAX', () async {
    await LocalDb.putDerivedFingerprint('2026-10-03', kAlgoVersion, '$_sec:120');
    expect(await _through(repo, '2026-10-03'),
        DateTime.fromMillisecondsSinceEpoch(_sec * 1000));
  });

  test('each day has its own', () async {
    await LocalDb.putDerivedFingerprint('2026-10-03', kAlgoVersion, '$_sec:1:0');
    await LocalDb.putDerivedFingerprint(
        '2026-10-02', kAlgoVersion, '${_sec - 86400}:1:0');
    expect(await _through(repo, '2026-10-02'),
        DateTime.fromMillisecondsSinceEpoch((_sec - 86400) * 1000));
    expect(await _through(repo, '2026-10-03'),
        DateTime.fromMillisecondsSinceEpoch(_sec * 1000));
  });

  test('absent: no fingerprint, another version, or one that does not parse '
      '-> null, never a made-up time', () async {
    expect(await _through(repo, '2026-10-03'), isNull, reason: 'no row');

    await LocalDb.putDerivedFingerprint(
        '2026-10-03', kAlgoVersion - 1, '$_sec:1:0');
    expect(await _through(repo, '2026-10-03'), isNull,
        reason: 'a fingerprint of another version describes another result');

    await LocalDb.putDerivedFingerprint('2026-10-03', kAlgoVersion, 'garbage');
    expect(await _through(repo, '2026-10-03'), isNull);

    await LocalDb.putDerivedFingerprint('2026-10-03', kAlgoVersion, '');
    expect(await _through(repo, '2026-10-03'), isNull);

    await LocalDb.putDerivedFingerprint('2026-10-03', kAlgoVersion, '0:5:0');
    expect(await _through(repo, '2026-10-03'), isNull,
        reason: 'rec_ts 0 is not a recording time');
  });

  test('the interface default is null (a repo that knows nothing)', () async {
    final fake = HomeRepo(homeBundle());
    expect(await (fake as dynamic).dayRecordingsThrough('2026-10-03'), isNull);
  });
}
