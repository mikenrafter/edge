// sample_lock.dart - one async queue for everything that WRITES the archive
// table: the pre-prune archiver and the backup restore. Each job starts when
// the one before it has finished, whether that one returned or threw, so a
// failure never wedges the queue (AGENTS 4.3: a latch is released in finally).
//
// This is a second line of defence. The insert transactions themselves decide
// coverage and part numbers inside the transaction, so they are correct even
// without it; the queue only stops a restore and an archive pass from doing
// the same work twice at the same time.
//
// Take it BEFORE opening a database transaction, never inside one: a job that
// holds the queue and waits for a transaction slot, behind a transaction that
// waits for the queue, would never finish.
import 'dart:async';

class SampleLock {
  SampleLock._();

  static Future<void> _tail = Future<void>.value();

  /// Run [job] once every earlier job is done. Not re-entrant.
  static Future<T> run<T>(Future<T> Function() job) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) => job()).whenComplete(done.complete);
  }
}
