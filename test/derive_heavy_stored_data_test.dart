// A caller that STORED data asks for a heavy pass with `storedData: true`, and
// that counts as new data for the running-pass dedupe whichever path stored it
// (a secondary wearable's sync, a banked workout tail, an import, a drain).
// Without it a wearable's rows that bank after a running heavy pass read its
// inputs are dropped with no follow-up.
//
// Assumed API: DeriveScheduler.requestHeavy({reason, bool storedData = false}).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _until(bool Function() ok,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<String>> _queued() async => [
      for (final r in await LocalDb.computeJobs(state: 'queued', limit: 20))
        r['type'].toString(),
    ]..sort();


Future<List<String>> _queued2() => _queued();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_heavy_stored_data_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() => LocalDb.close());
  setUp(() async => (await LocalDb.instance).delete('compute_jobs'));

  DeriveScheduler? made;
  tearDown(() {
    made?.dispose();
    made = null;
  });

  DeriveScheduler build(List<DeriveJobKind> kinds, List<Completer<void>> gates) {
    return made = DeriveScheduler(
      run: ({required DeriveJobKind kind}) async {
        kinds.add(kind);
        final i = kinds.length - 1;
        if (i < gates.length) await gates[i].future;
        return const DeriveOutcome(computed: 1);
      },
      log: (_) {},
      onChanged: () {},
      lightSettle: const Duration(milliseconds: 10),
      heavySettle: const Duration(milliseconds: 10),
    );
  }

  test('a stored-data heavy request during a heavy pass queues a follow-up',
      () async {
    final kinds = <DeriveJobKind>[];
    final gate = Completer<void>();
    final s = build(kinds, [gate]);
    s.requestHeavy();
    await _until(() => kinds.length == 1);

    s.requestHeavy(reason: 'wearable_sync', storedData: true);
    await _until(() => false, timeout: const Duration(milliseconds: 200));
    expect(await _queued2(), ['derive_heavy']);

    gate.complete();
    await _until(() => kinds.length == 2);
    expect(kinds, [DeriveJobKind.heavy, DeriveJobKind.heavy]);
  });

  test('a stored-data request does not also queue a light job', () async {
    final kinds = <DeriveJobKind>[];
    final gate = Completer<void>();
    final s = build(kinds, [gate]);
    s.requestHeavy();
    await _until(() => kinds.length == 1);
    s.requestHeavy(storedData: true);
    await _until(() => false, timeout: const Duration(milliseconds: 200));
    expect(await _queued2(), isNot(contains('derive_light')));
    gate.complete();
  });

  test('every storing caller asks with storedData: true (source scan)', () {
    String read(String path) => File(path).readAsStringSync();
    final app = read('lib/state/app_state.dart');
    expect(
        RegExp(r'onWearableStored\s*=\s*\(\)\s*=>\s*_deriveScheduler\s*\.requestHeavy\([^)]*storedData:\s*true')
            .hasMatch(app),
        isTrue,
        reason: 'wearable sync banks rows without markStoredData');
    expect(
        RegExp(r"requestHeavyDerive:\s*\(\)\s*=>\s*_deriveScheduler\.requestHeavy\([^)]*storedData:\s*true")
            .hasMatch(app),
        isTrue,
        reason: 'a banked workout tail is stored data');
    expect(
        RegExp(r"requestHeavy\(reason:\s*'import',\s*storedData:\s*true\)")
            .hasMatch(app),
        isTrue,
        reason: 'an import is stored data');
    final sync = read('lib/state/sync_controller.dart');
    expect(RegExp(r'requestHeavy\(storedData:\s*true\)').allMatches(sync).length,
        2,
        reason: 'both post-drain steps store before they ask');
  });
}
