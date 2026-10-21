// A heavy derive request is conditional on there being something new to read.
//
// The loop: a reconnect drain asks for a heavy pass while one is already
// running. The queue dedupes against QUEUED heavy jobs only, so the request
// lands as a follow-up pass that re-reads the same data, and that pass's own
// reconnect asks again.
//
// Contract pinned here (scheduler, no new API):
//   * requestHeavy while a heavy pass runs and markStoredData() has not been
//     called since that pass started => nothing is queued.
//   * requestHeavy after markStoredData() since the pass started => a
//     follow-up heavy job is queued and runs.

import 'dart:async';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_heavy_conditional_test.db';
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

  /// A scheduler whose passes park on [gates] in order, recording each kind.
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

  test('a heavy request during a heavy pass, with no new data, queues nothing',
      () async {
    final kinds = <DeriveJobKind>[];
    final gate = Completer<void>();
    final s = build(kinds, [gate]);
    s.requestHeavy();
    await _until(() => kinds.length == 1);
    expect(s.running, isTrue);

    s.requestHeavy(reason: 'reconnect_drain');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await _queued(), isEmpty,
        reason: 'the running pass already read everything stored');

    gate.complete();
    await _until(() => !s.running);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(kinds, [DeriveJobKind.heavy], reason: 'no follow-up pass');
  });

  test('a heavy request after new data was stored during the pass queues a '
      'follow-up that runs', () async {
    final kinds = <DeriveJobKind>[];
    final gate = Completer<void>();
    final s = build(kinds, [gate]);
    s.requestHeavy();
    await _until(() => kinds.length == 1);

    s.markStoredData();
    s.requestHeavy(reason: 'reconnect_drain');
    await _until(() => false, timeout: const Duration(milliseconds: 200));
    expect(await _queued(), ['derive_heavy']);

    gate.complete();
    await _until(() => kinds.length == 2);
    expect(kinds, [DeriveJobKind.heavy, DeriveJobKind.heavy]);
  });

  test('control: with no pass running, a heavy request is queued', () async {
    final kinds = <DeriveJobKind>[];
    final s = build(kinds, []);
    s.requestHeavy();
    await _until(() => kinds.length == 1);
    expect(kinds, [DeriveJobKind.heavy]);
  });
}
