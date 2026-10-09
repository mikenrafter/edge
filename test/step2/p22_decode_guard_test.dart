// P2.2 guards (design 02 step 2, sections 4.2 and 5): the stored-payload
// decode has one door, and it opens onto a registered @heavy worker entry.
//
//   1. `SeriesCodec.decodePayloadJson` is called only from BundleStore and
//      worker entries. Callers outside lib/data/bundle_store.dart that other
//      phases still own are listed below with the phase that removes them; the
//      list only shrinks, a listed file that no longer calls must be deleted
//      from it, and LocalRepositoryImpl is NOT on it.
//   2. `decodeDayPayloadsHeavy` is a registered `Dispatcher.run` entry, marked
//      @heavy, and the production lane dispatches it with `Isolate.run`.
//   3. A read really runs the entry in ANOTHER isolate, for the dispatch that
//      asked (the dispatcher audit), including through a repository reader.
//   4. The heavy-calc baseline no longer carries
//      `LocalRepositoryImpl._decode` (the firm -1 of P2.2).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

import '../support/dart_source.dart';
import 'support/p22_support.dart';

const _name = 'p22_decode_guard.db';

/// Files (relative to lib/) that may still call the codec's decode, and the
/// phase that moves each one. Shrink-only.
const Map<String, String> _legacyCallers = {
  'data/series_codec.dart': 'the codec itself',
  'data/bundle_store.dart': 'the one door (P2.2)',
  'data/db.dart': 'P2.3 refreshComputeFreshness, P2.5 recentDayDiagnostics, P2.10 putDayResult',
  'compute/derivation_engine.dart': 'P2.9 _decodeBundle and the derive-side reads',
  'compute/crossday_input.dart': 'P2.9 assembleCrossDayInput',
  'health/health_export.dart': 'P2.5 HealthExporter streaming',
  'state/app_state.dart': 'P2.5 _maybeNotifyRecoveryReady',
};

/// Files that always exempt: the codec defines it, the store may use it.
const _door = {'data/series_codec.dart', 'data/bundle_store.dart'};

Set<String> _callers() {
  final out = <String>{};
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final code = stripCommentsAndStrings(f.readAsStringSync());
    if (RegExp(r'decodePayloadJson|SeriesCodec\s*\.\s*decodePayload\b').hasMatch(code)) {
      out.add(f.path.substring('lib/'.length));
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  group('one door for the stored-payload decode', () {
    test('only BundleStore, worker entries and the listed legacy callers call '
        'SeriesCodec.decodePayloadJson', () {
      final callers = _callers();
      expect(
        callers.difference(_legacyCallers.keys.toSet()),
        isEmpty,
        reason: 'a new decode site: route it through BundleStore',
      );
      expect(callers, isNot(contains('data/local_repository_impl.dart')),
          reason: 'P2.2 moves the repository\'s decode into BundleStore');
    });

    test('every listed legacy caller still calls (the list only shrinks)', () {
      final callers = _callers();
      final stale = [
        for (final f in _legacyCallers.keys)
          if (!_door.contains(f) && !callers.contains(f)) f,
      ];
      expect(stale, isEmpty, reason: 'delete these lines from _legacyCallers');
    });

    test('the heavy-calc baseline no longer lists LocalRepositoryImpl._decode',
        () {
      final base = jsonDecode(
        File('test/guards/heavy_calc_baseline.json').readAsStringSync(),
      ) as Map;
      final hits = [
        for (final o in (base['occurrences'] as List).cast<Map>())
          if (o['symbol'] == 'LocalRepositoryImpl._decode') o,
      ];
      expect(hits, isEmpty);
    });
  });

  group('the decode entry is registered', () {
    test('decodeDayPayloadsHeavy is a Dispatcher.run row in kWorkerEntries', () {
      final rows = kWorkerEntries
          .where((w) => w.symbol.toString().contains('decodeDayPayloadsHeavy'))
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.dispatcher, Dispatcher.run);
      expect(rows.single.reason, isNotEmpty);
    });

    test('it is @heavy, starts with the worker header, and the production lane '
        'hands it to Isolate.run under a dispatcher audit label', () {
      final src = File('lib/data/bundle_store.dart').readAsStringSync();
      expect(
        RegExp(r'@heavy\s+DecodedChunk decodeDayPayloadsHeavy\(').hasMatch(src),
        isTrue,
      );
      final body = src.substring(src.indexOf('decodeDayPayloadsHeavy('));
      expect(body.indexOf('WorkerInit.ensure'), lessThan(body.indexOf('assertWorker')));
      expect(src, contains('Dispatcher.run'));
      expect(src, contains('Isolate.run'));
      expect(src, contains("WorkerAudit.entered('decodeDayPayloadsHeavy')"));
    });
  });

  group('a read runs the entry in another isolate', () {
    late Database db;
    setUp(() async {
      db = await p21Fresh(_name);
      BundleStore.debugResetShared();
    });
    tearDown(() async {
      WorkerAudit.reset();
      BundleStore.debugResetShared();
      await p21Drop(_name);
    });

    test('BundleStore.read with the production lane: one dispatch, one entry '
        'report from a different isolate carrying that dispatch id', () async {
      final dispatches = <DispatchEvent>[];
      final entries = <EntryEvent>[];
      WorkerAudit.onDispatch = dispatches.add;
      WorkerAudit.onEntry = entries.add;
      await p22Put('2026-03-10', 'a');

      final r = await BundleStore().read(const BundleSource.day('2026-03-10'));

      expect(p22TagOf(r), 'a');
      final mine = dispatches.where((d) => d.label == 'bundle decode').toList();
      expect(mine, hasLength(1));
      expect(mine.single.kind, Dispatcher.run);
      await p22Until(() => entries.isNotEmpty, 'the worker reports its entry');
      final e = entries.singleWhere((e) => e.entry == 'decodeDayPayloadsHeavy');
      expect(e.isolateId, isNot(WorkerAudit.currentIsolateId));
      expect(e.dispatchId, mine.single.id);
    });

    test('a repository reader never decodes on the UI isolate: the entry '
        'reports from a worker, never from this isolate', () async {
      final entries = <EntryEvent>[];
      WorkerAudit.onEntry = entries.add;
      await p22Seed(db, p22D1, p22DayBundle(p22D1, i: 1));
      final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

      final out = await repo.getDayHrv(p22D1);

      expect(out['rmssd'], 41.0);
      await p22Until(() => entries.isNotEmpty, 'the worker reports its entry');
      expect(entries.map((e) => e.entry).toSet(), {'decodeDayPayloadsHeavy'});
      expect(entries.map((e) => e.isolateId),
          everyElement(isNot(WorkerAudit.currentIsolateId)));
    });
  });
}
