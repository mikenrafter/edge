// 8AK D (red): the persisted failure record behind the Home card and the
// Settings list.
//
// USER: "On a failed activation (ECG or non-ECG), persist a failure record
// (time, kind ECG / double-tap, reason, gesture id; bounded, e.g. last 20).
// ... Only the newest undismissed failure shows; dismiss persists."
//
// ASSUMED API (NEW lib/gestures/gesture_failures.dart):
//   enum GestureFailureKind { ecg, doubleTap }
//
//   class GestureFailure {            // immutable
//     final String gestureId;         // the cues' base id: the tap identity
//     final DateTime at;              // when it failed (the store's clock)
//     final GestureFailureKind kind;
//     final String reason;            // 'start_failed', 'link_lost', or for a
//                                     // double tap the action that failed
//     final String log;               // the relevant session log, plain text
//     final bool dismissed;
//     Object toJson();  factory GestureFailure.fromJson(Object?)  // may throw
//   }
//
//   class GestureFailureStore extends ChangeNotifier {
//     GestureFailureStore({String? Function()? read,
//         Future<void> Function(String json)? write, DateTime Function()? now});
//         // read/write: the one persisted string (production: Prefs, key
//         // 'gesture_failures'); loaded in the constructor, rewritten on every
//         // change. Unreadable stored data is an empty store, never a throw.
//         // A write that throws is swallowed (the in-memory state stands).
//     static const int maxKept = 20;          // newest kept, oldest dropped
//     static const int maxLogChars = 60000;   // a longer log keeps its END
//     List<GestureFailure> get all;           // newest first, unmodifiable
//     GestureFailure? get newestUndismissed;  // what Home shows, or null
//     Future<GestureFailure?> record({required GestureFailureKind kind,
//         required String reason, required String gestureId, String log = '',
//         DateTime? at});
//         // null (and nothing stored, no notify) when [gestureId] is already
//         // recorded: one failure, one record, however often it is reported.
//     Future<void> dismiss(String gestureId);
//         // marks that failure AND every older one dismissed (a dismissed card
//         // supersedes the failures before it: they stay listed, marked
//         // dismissed, and never resurface on Home). Unknown id: no-op.
//   }
//
// Failure mode today: the file does not exist (this file does not compile
// until it does).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 4, 2, 7, 31);

class _Backing {
  String? raw;
  int writes = 0;
  bool throws = false;

  GestureFailureStore store({DateTime Function()? now}) => GestureFailureStore(
        read: () => raw,
        write: (s) async {
          writes++;
          if (throws) throw StateError('disk full');
          raw = s;
        },
        now: now ?? () => _t0,
      );
}

Future<GestureFailure?> _fail(GestureFailureStore s, String id,
        {GestureFailureKind kind = GestureFailureKind.ecg,
        String reason = 'start_failed',
        String? log,
        DateTime? at}) =>
    s.record(
        kind: kind,
        reason: reason,
        gestureId: id,
        log: log ?? 'log of $id',
        at: at);

void main() {
  test('a fresh store is empty and shows nothing', () {
    final s = _Backing().store();
    expect(s.all, isEmpty);
    expect(s.newestUndismissed, isNull);
  });

  test('a failure keeps its time, kind, reason, gesture id and log', () async {
    final b = _Backing();
    final s = b.store();
    final f = await s.record(
      kind: GestureFailureKind.ecg,
      reason: 'start_failed',
      gestureId: '1791101224:14',
      log: 'Double tap received.\nECG failed (start_failed).',
      at: _t0,
    );
    expect(f, isNotNull);
    expect(s.all, hasLength(1));
    final g = s.all.single;
    expect(g.gestureId, '1791101224:14');
    expect(g.at, _t0);
    expect(g.kind, GestureFailureKind.ecg);
    expect(g.reason, 'start_failed');
    expect(g.log, contains('ECG failed (start_failed).'));
    expect(g.dismissed, isFalse);
  });

  test('the time defaults to the store\'s clock', () async {
    final s = _Backing().store(now: () => _t0.add(const Duration(minutes: 3)));
    await s.record(
        kind: GestureFailureKind.doubleTap, reason: 'water', gestureId: 'x');
    expect(s.all.single.at, _t0.add(const Duration(minutes: 3)));
  });

  test('newest first; the newest undismissed one is what Home shows',
      () async {
    final s = _Backing().store();
    await _fail(s, 'a', at: _t0);
    await _fail(s, 'b', at: _t0.add(const Duration(minutes: 1)));
    await _fail(s, 'c', at: _t0.add(const Duration(minutes: 2)));
    expect([for (final f in s.all) f.gestureId], ['c', 'b', 'a']);
    expect(s.newestUndismissed!.gestureId, 'c');
  });

  test('one failure, one record: reporting the same gesture twice stores '
      'and notifies once', () async {
    final s = _Backing().store();
    var notified = 0;
    s.addListener(() => notified++);
    expect(await _fail(s, 'a'), isNotNull);
    expect(await _fail(s, 'a', reason: 'link_lost'), isNull);
    expect(s.all, hasLength(1));
    expect(s.all.single.reason, 'start_failed', reason: 'the first report stands');
    expect(notified, 1);
  });

  group('bounded', () {
    test('the newest 20 are kept, the oldest dropped', () async {
      final s = _Backing().store();
      for (var i = 0; i < 25; i++) {
        await _fail(s, 'g$i', at: _t0.add(Duration(minutes: i)));
      }
      expect(GestureFailureStore.maxKept, 20);
      expect(s.all, hasLength(20));
      expect(s.all.first.gestureId, 'g24');
      expect(s.all.last.gestureId, 'g5');
    });

    test('a very long log keeps its end, where the failure is', () async {
      final s = _Backing().store();
      final big = '${'x' * 100000}THE END';
      await _fail(s, 'a', log: big);
      final log = s.all.single.log;
      expect(log.length, lessThanOrEqualTo(GestureFailureStore.maxLogChars));
      expect(log, endsWith('THE END'));
    });
  });

  group('dismiss', () {
    test('the dismissed failure no longer shows; it stays in the list',
        () async {
      final s = _Backing().store();
      await _fail(s, 'a');
      await s.dismiss('a');
      expect(s.newestUndismissed, isNull);
      expect(s.all.single.dismissed, isTrue);
    });

    test('a new failure after a dismissal shows again', () async {
      final s = _Backing().store();
      await _fail(s, 'a', at: _t0);
      await s.dismiss('a');
      await _fail(s, 'b', at: _t0.add(const Duration(minutes: 5)));
      expect(s.newestUndismissed!.gestureId, 'b');
    });

    test('dismissing the newest also settles the older ones: they do not '
        'resurface (one card at a time, never a pile)', () async {
      final s = _Backing().store();
      await _fail(s, 'a', at: _t0);
      await _fail(s, 'b', at: _t0.add(const Duration(minutes: 1)));
      expect(s.newestUndismissed!.gestureId, 'b');
      await s.dismiss('b');
      expect(s.newestUndismissed, isNull);
      expect([for (final f in s.all) f.dismissed], [true, true]);
    });

    test('an unknown id changes nothing and does not notify', () async {
      final s = _Backing().store();
      await _fail(s, 'a');
      var notified = 0;
      s.addListener(() => notified++);
      await s.dismiss('nope');
      expect(s.newestUndismissed!.gestureId, 'a');
      expect(notified, 0);
    });

    test('listeners hear a record and a dismissal', () async {
      final s = _Backing().store();
      var notified = 0;
      s.addListener(() => notified++);
      await _fail(s, 'a');
      await s.dismiss('a');
      expect(notified, 2);
    });
  });

  group('persistence', () {
    test('the failures survive a restart, still undismissed', () async {
      final b = _Backing();
      await _fail(b.store(), 'a');
      final again = b.store();
      expect(again.all.single.gestureId, 'a');
      expect(again.newestUndismissed!.gestureId, 'a',
          reason: 'not dismissed: the card shows again after a restart');
    });

    test('a dismissal survives a restart', () async {
      final b = _Backing();
      final s = b.store();
      await _fail(s, 'a', at: _t0);
      await _fail(s, 'b', at: _t0.add(const Duration(minutes: 1)));
      await s.dismiss('b');
      final again = b.store();
      expect(again.newestUndismissed, isNull);
      expect(again.all, hasLength(2));
      expect(again.all.every((f) => f.dismissed), isTrue);
    });

    test('every field round-trips', () async {
      final b = _Backing();
      await _fail(b.store(), 'a',
          kind: GestureFailureKind.doubleTap,
          reason: 'log_water: no band',
          log: 'a\nb',
          at: _t0);
      final g = b.store().all.single;
      expect(g.kind, GestureFailureKind.doubleTap);
      expect(g.reason, 'log_water: no band');
      expect(g.log, 'a\nb');
      expect(g.at, _t0);
    });

    test('unreadable stored data is an empty store, not a throw', () {
      for (final junk in const ['', 'not json', '{"a":1}', '[1,2]', '[{"x":1}]']) {
        final b = _Backing()..raw = junk;
        expect(() => b.store(), returnsNormally, reason: junk);
        expect(b.store().all, isEmpty, reason: junk);
      }
    });

    test('a good entry survives a bad neighbour', () async {
      final b = _Backing();
      await _fail(b.store(), 'a');
      b.raw = b.raw!.replaceFirst('[', '[{"x":1},');
      expect(b.store().all.map((f) => f.gestureId), ['a']);
    });

    test('a failing write is swallowed: the in-memory state stands', () async {
      final b = _Backing()..throws = true;
      final s = b.store();
      await _fail(s, 'a');
      expect(s.newestUndismissed!.gestureId, 'a');
    });
  });
}
