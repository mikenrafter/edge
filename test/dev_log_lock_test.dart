// The dev log's append lock (lib/sync/dev_log.dart `_appendLocked`): a lock file
// `dev_log/.append.lock`, created with the atomic exclusive create, makes an
// append a critical section across isolates. A lock older than `lockWait`
// belongs to a dead writer and is taken over.
//
// Three review findings are pinned here, all red against the current code:
//   1. The takeover decision uses the WAITER's own elapsed time, not the lock's
//      age or identity. Two waiters on one abandoned lock both reach their
//      deadline; the second deletes the FRESH lock the first just made, both
//      append at once, and a writer's `finally` deletes whatever lock is there
//      (maybe another writer's).
//   3. Any FileSystemException except not-found is "contention". An exclusive
//      create that can never succeed (here: the lock path is a directory; a
//      full disk or a read-only folder fail the same way) loops forever, since
//      the stopwatch resets after each failed takeover. That blocks `_chain`,
//      so every later write and the export's `flush()` hang too.
//
// The critical section is held open deterministically with
// `IOOverrides.runZoned`: a File wrapper for the day file whose writeAsBytes
// waits on a gate. Only DevLog calls made inside that zone are affected, so one
// "isolate" can be slow while another is not. No production seam is needed.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/dev_log.dart';
import 'package:openstrap_edge/sync/dev_log_export.dart';

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

/// The day file as seen by DevLog inside the gated zone: the real write only
/// happens once the gate opens, so the writer sits inside its critical section.
class _GatedFile implements File {
  _GatedFile(this._path, this._gate);
  final String _path;
  final _Gate _gate;

  @override
  Future<File> writeAsBytes(List<int> bytes,
      {FileMode mode = FileMode.write, bool flush = false}) async {
    if (!_gate.entered.isCompleted) _gate.entered.complete();
    await _gate.release.future;
    // Zone.root has no IOOverrides: this is the real file.
    return Zone.root
        .run(() => File(_path).writeAsBytes(bytes, mode: mode, flush: flush));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_GatedFile.${invocation.memberName}');
}

/// Run [body] with every `dev-*.log` File made inside it gated by [gate].
T _gated<T>(_Gate gate, T Function() body) => IOOverrides.runZoned(body,
    createFile: (path) => path.contains('/dev-') && path.endsWith('.log')
        ? _GatedFile(path, gate)
        : Zone.root.run(() => File(path)));

Future<void> _delay(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Directory base;
  final clock = DateTime(2026, 10, 6, 12, 0, 0, 123);

  DevLog make({int lockWaitMs = 200}) => DevLog(
        baseDir: () async => base,
        now: () => clock,
        devMode: () async => true,
        lockWait: Duration(milliseconds: lockWaitMs),
      );

  File lock() => File('${base.path}/dev_log/.append.lock');
  File dayFile() => File('${base.path}/dev_log/dev-2026-10-06.log');
  String dayText() => dayFile().existsSync() ? dayFile().readAsStringSync() : '';
  List<String> records() => dayText()
      .split('\n')
      .where((l) => l.isNotEmpty && !l.contains('[devlog] opened'))
      .toList();

  setUp(() async {
    base = await Directory.systemTemp.createTemp('dev_log_lock_');
    Directory('${base.path}/dev_log').createSync(recursive: true);
  });
  tearDown(() async {
    if (await base.exists()) await base.delete(recursive: true);
  });

  group('stale takeover is decided by the lock, not by the waiter', () {
    test('a fresh lock made after the waiter started waiting is not taken over',
        () async {
      // t=0: an abandoned lock; the waiter starts waiting on it.
      lock().createSync();
      final log = make(lockWaitMs: 400);
      final w = log.add('[alarm] waiter', always: true);
      await _delay(100);
      await _delay(100);
      await _delay(40);
      // t~240: another writer takes that lock over and now holds a LIVE one.
      lock().deleteSync();
      lock().createSync(exclusive: true);
      final liveSince = Stopwatch()..start();

      // The waiter's own 400 ms run out at t~400; the live lock is then only
      // ~160 ms old and must survive until it is 400 ms old (t~640). Watch to
      // t~500 (live lock age ~260 ms).
      while (liveSince.elapsedMilliseconds < 260) {
        expect(lock().existsSync(), isTrue,
            reason: 'the waiter deleted a lock that was only '
                '${liveSince.elapsedMilliseconds} ms old (lockWait is 400 ms): '
                'it measured its own waiting time, not the lock\'s age');
        expect(records(), isEmpty,
            reason: 'the waiter entered the critical section while another '
                'writer held a live lock');
        await _delay(10);
      }

      // The other writer finishes; the waiter then gets its turn.
      lock().deleteSync();
      await w.timeout(const Duration(seconds: 5));
      expect(records().single, endsWith('[ui] [alarm] waiter'));
    });

    test('a writer never releases a lock it no longer owns', () async {
      final gate = _Gate();
      final log = make();
      final w = _gated(gate, () => log.add('[alarm] slow', always: true));
      await gate.entered.future.timeout(const Duration(seconds: 5));
      expect(lock().existsSync(), isTrue, reason: 'the writer holds the lock');

      // The writer was slow; another writer took the lock over and holds its own.
      await _delay(30);
      lock().deleteSync();
      lock().createSync(exclusive: true);

      gate.release.complete();
      await w.timeout(const Duration(seconds: 5));
      expect(records().single, endsWith('[ui] [alarm] slow'));
      expect(lock().existsSync(), isTrue,
          reason: 'the first writer\'s release deleted the other writer\'s lock');
    });

    test('two writers on one abandoned lock never hold the critical section '
        'together, and every line lands whole', () async {
      lock().createSync(); // abandoned by a writer that died
      final gate = _Gate();
      final a = make(), b = make();

      // A starts waiting first, takes over at ~200 ms and is then inside the
      // critical section (held open by the gate).
      final fa = _gated(gate, () => a.add('[alarm] from A', always: true));
      await _delay(60);
      // B starts waiting 60 ms later: its own 200 ms run out at ~260 ms, when
      // A's lock is only ~60 ms old.
      final fb = b.add('[alarm] from B', always: true);
      await gate.entered.future.timeout(const Duration(seconds: 5));

      // A holds a live lock (~0 ms old). Over the next 100 ms B's deadline
      // passes; B must still be waiting, not writing alongside A.
      await _delay(100);
      expect(records().where((l) => l.contains('from B')), isEmpty,
          reason: 'B deleted A\'s fresh lock and wrote while A was inside the '
              'critical section');

      gate.release.complete();
      await Future.wait([fa, fb]).timeout(const Duration(seconds: 5));
      final recs = records();
      expect(recs, hasLength(2), reason: 'a line was lost: $recs');
      for (final r in recs) {
        expect(r, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T[\d:.+-]+ \[ui\] '
            r'\[alarm\] from [AB]$')));
      }
      expect(lock().existsSync(), isFalse, reason: 'every lock is released');
    });
  });

  group('a lock that can never be created does not wedge the log', () {
    // A directory where the lock file must go: the exclusive create fails with
    // a FileSystemException that is not "not found" and never clears by itself.
    void block() => Directory(lock().path).createSync();
    void unblock() {
      final d = Directory(lock().path);
      if (d.existsSync()) d.deleteSync();
    }

    test('one write completes in bounded time (drops or falls back)', () async {
      block();
      addTearDown(unblock); // lets a spinning current-code loop end
      final log = make(lockWaitMs: 50);
      await log
          .add('[alarm] cannot lock', always: true)
          .timeout(const Duration(seconds: 3), onTimeout: () {
        fail('the write never completed: an exclusive create that can never '
            'succeed was retried forever as if it were lock contention');
      });
    });

    test('flush and later writes do not hang behind it, and the export of '
        'the log completes', () async {
      block();
      addTearDown(unblock);
      final log = make(lockWaitMs: 50);
      unawaited(log.add('[alarm] first', always: true));
      unawaited(log.add('[alarm] second', always: true));
      final out = await Directory.systemTemp.createTemp('dev_log_lock_out_');
      addTearDown(() => out.delete(recursive: true));
      final zip = await exportDevLogZip(log,
              outDir: out,
              now: clock,
              wakeTrace: () async => const [])
          .timeout(const Duration(seconds: 5), onTimeout: () {
        fail('export hung: flush() waited on a write stuck in the lock loop');
      });
      expect(zip.existsSync(), isTrue);

      // Once the obstruction is gone the log writes again.
      unblock();
      await log.add('[alarm] after', always: true)
          .timeout(const Duration(seconds: 5));
      expect(records().last, endsWith('[alarm] after'));
    });
  });
}
