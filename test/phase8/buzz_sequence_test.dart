// 8D — BuzzSequence: encoding, defaults, recorder and playback.
//
// Pure model + timing in lib/notify/buzz_sequence.dart. Time is fake
// (package:fake_async), and the recorder reads package:clock, which fake_async
// drives. See test/phase8/CONTRACTS.md §8D.

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

void main() {
  group('BuzzSequence validation', () {
    test('accepts a single buzz and the documented example', () {
      expect(BuzzSequence(const [0]).offsetsMs, [0]);
      expect(BuzzSequence(const [0, 500, 1000]).offsetsMs, [0, 500, 1000]);
      expect(BuzzSequence(const [0, 500, 1000]).length, 3);
    });

    test('accepts the edges: 8 buzzes, 150 ms and 2000 ms gaps', () {
      expect(BuzzSequence([for (var i = 0; i < 8; i++) i * 150]).length, 8);
      expect(BuzzSequence(const [0, 2000]).offsetsMs, [0, 2000]);
    });

    for (final (name, bad) in [
      ('empty', <int>[]),
      ('nine buzzes', [for (var i = 0; i < 9; i++) i * 200]),
      ('does not start at 0', [100, 400]),
      ('negative start', [-10, 300]),
      ('not increasing', [0, 500, 500]),
      ('decreasing', [0, 800, 400]),
      ('gap under 150 ms', [0, 149]),
      ('gap over 2000 ms', [0, 2001]),
    ]) {
      test('rejects $name', () {
        expect(() => BuzzSequence(bad), throwsArgumentError);
      });
    }

    test('offsets are not mutable through the getter', () {
      final s = BuzzSequence(const [0, 500]);
      expect(() => s.offsetsMs.add(900), throwsUnsupportedError);
    });

    test('value equality', () {
      expect(BuzzSequence(const [0, 500]), BuzzSequence(const [0, 500]));
      expect(BuzzSequence(const [0, 500]).hashCode,
          BuzzSequence(const [0, 500]).hashCode);
      expect(BuzzSequence(const [0, 500]),
          isNot(BuzzSequence(const [0, 600])));
    });

    test('the limits are named constants', () {
      expect(BuzzSequence.maxBuzzes, 8);
      expect(BuzzSequence.minGapMs, 150);
      expect(BuzzSequence.maxGapMs, 2000);
    });
  });

  group('BuzzSequence JSON', () {
    test('round-trips as a plain list of ints', () {
      final s = BuzzSequence(const [0, 300, 900, 1200]);
      final json = s.toJson();
      expect(json, [0, 300, 900, 1200]);
      expect(BuzzSequence.fromJson(jsonDecode(jsonEncode(json))), s);
    });

    for (final (name, raw) in [
      ('null', null),
      ('a map', {'offsets': [0]}),
      ('a string', '0,500'),
      ('non-int entries', [0, 'x']),
      ('doubles', [0, 500.5]),
      ('an invalid sequence', [0, 100]),
      ('empty', <int>[]),
    ]) {
      test('rejects $name with a FormatException', () {
        expect(() => BuzzSequence.fromJson(raw), throwsFormatException);
      });
    }
  });

  group('default assignment: [1,2,3] x [500,1000,1500] ms, count-major', () {
    // index i -> count = (i % 9) % 3 + 1, gap = [500,1000,1500][(i % 9) ~/ 3]
    const expected = <List<int>>[
      [0], //               1 x 500
      [0, 500], //          2 x 500
      [0, 500, 1000], //    3 x 500
      [0], //               1 x 1000
      [0, 1000], //         2 x 1000
      [0, 1000, 2000], //   3 x 1000
      [0], //               1 x 1500
      [0, 1500], //         2 x 1500
      [0, 1500, 3000], //   3 x 1500
    ];
    for (var i = 0; i < expected.length; i++) {
      test('index $i -> ${expected[i]}', () {
        expect(BuzzSequence.defaultFor(i).offsetsMs, expected[i]);
      });
    }

    test('wraps after nine', () {
      for (var i = 0; i < 9; i++) {
        expect(BuzzSequence.defaultFor(i + 9), BuzzSequence.defaultFor(i));
        expect(BuzzSequence.defaultFor(i + 18), BuzzSequence.defaultFor(i));
      }
    });

    test('rejects a negative index', () {
      expect(() => BuzzSequence.defaultFor(-1), throwsArgumentError);
    });
  });

  group('BuzzRecorder (fake clock)', () {
    test('first tap starts recording and buzzes the phone once', () {
      fakeAsync((async) {
        var phone = 0;
        final r = BuzzRecorder(onStart: () => phone++);
        expect(r.recording, isFalse);
        r.tap();
        expect(r.recording, isTrue);
        async.elapse(const Duration(milliseconds: 400));
        r.tap();
        expect(phone, 1);
        r.dispose();
      });
    });

    test('ends 2 s after the last tap, not before', () {
      fakeAsync((async) {
        final done = <BuzzSequence>[];
        final r = BuzzRecorder(onDone: done.add);
        r.tap();
        async.elapse(const Duration(milliseconds: 400));
        r.tap();
        async.elapse(const Duration(milliseconds: 400));
        r.tap();
        async.elapse(const Duration(milliseconds: 1999));
        expect(r.recording, isTrue);
        expect(r.result, isNull);
        expect(done, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(r.recording, isFalse);
        expect(r.result, BuzzSequence(const [0, 400, 800]));
        expect(done, [BuzzSequence(const [0, 400, 800])]);
        async.elapse(const Duration(seconds: 10));
        expect(done, hasLength(1), reason: 'onDone fires once');
        r.dispose();
      });
    });

    test('a single tap followed by silence is a one-buzz sequence', () {
      fakeAsync((async) {
        final r = BuzzRecorder();
        r.tap();
        async.elapse(const Duration(seconds: 2));
        expect(r.result, BuzzSequence(const [0]));
        r.dispose();
      });
    });

    test('ends at the 8th tap and ignores the rest', () {
      fakeAsync((async) {
        final done = <BuzzSequence>[];
        final r = BuzzRecorder(onDone: done.add);
        for (var i = 0; i < 8; i++) {
          if (i > 0) async.elapse(const Duration(milliseconds: 200));
          r.tap();
        }
        // No 2 s wait: the eighth tap ends it.
        expect(r.recording, isFalse);
        expect(r.result!.offsetsMs, [for (var i = 0; i < 8; i++) i * 200]);
        async.elapse(const Duration(milliseconds: 200));
        r.tap();
        r.tap();
        expect(r.result!.length, 8);
        expect(done, hasLength(1));
        r.dispose();
      });
    });

    test('a tap under 150 ms after the previous one is ignored', () {
      fakeAsync((async) {
        final r = BuzzRecorder();
        r.tap();
        async.elapse(const Duration(milliseconds: 100));
        r.tap(); // bounce
        async.elapse(const Duration(milliseconds: 200));
        r.tap(); // 300 ms after the first
        async.elapse(const Duration(seconds: 2));
        expect(r.result, BuzzSequence(const [0, 300]));
        r.dispose();
      });
    });

    test('reset starts over', () {
      fakeAsync((async) {
        final r = BuzzRecorder();
        r.tap();
        async.elapse(const Duration(seconds: 2));
        expect(r.result, isNotNull);
        r.reset();
        expect(r.result, isNull);
        expect(r.recording, isFalse);
        r.tap();
        async.elapse(const Duration(milliseconds: 500));
        r.tap();
        async.elapse(const Duration(seconds: 2));
        expect(r.result, BuzzSequence(const [0, 500]));
        r.dispose();
      });
    });
  });

  group('playBuzzSequence (fake clock)', () {
    test('plays one single buzz at each offset from the first', () {
      fakeAsync((async) {
        final at = <Duration>[];
        bool? ok;
        playBuzzSequence(
          BuzzSequence(const [0, 300, 900]),
          buzz: () async {
            at.add(async.elapsed);
            return true;
          },
          isConnected: () => true,
        ).then((v) => ok = v);
        async.elapse(const Duration(seconds: 5));
        expect(at, const [
          Duration.zero,
          Duration(milliseconds: 300),
          Duration(milliseconds: 900),
        ]);
        expect(ok, isTrue);
      });
    });

    test('offsets are measured from the start, not after each write', () {
      fakeAsync((async) {
        final at = <Duration>[];
        playBuzzSequence(
          BuzzSequence(const [0, 300, 900]),
          buzz: () async {
            at.add(async.elapsed);
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return true;
          },
          isConnected: () => true,
        );
        async.elapse(const Duration(seconds: 5));
        expect(at, const [
          Duration.zero,
          Duration(milliseconds: 300),
          Duration(milliseconds: 900),
        ]);
      });
    });

    test('a disconnect mid-sequence stops further steps and reports failure',
        () {
      fakeAsync((async) {
        var n = 0;
        var connected = true;
        bool? ok;
        playBuzzSequence(
          BuzzSequence(const [0, 300, 600, 900]),
          buzz: () async {
            n++;
            if (n == 2) connected = false;
            return true;
          },
          isConnected: () => connected,
        ).then((v) => ok = v);
        async.elapse(const Duration(seconds: 5));
        expect(n, 2);
        expect(ok, isFalse);
      });
    });

    test('a failed write stops further steps and reports failure', () {
      fakeAsync((async) {
        var n = 0;
        bool? ok;
        playBuzzSequence(
          BuzzSequence(const [0, 300, 600]),
          buzz: () async => ++n != 2,
          isConnected: () => true,
        ).then((v) => ok = v);
        async.elapse(const Duration(seconds: 5));
        expect(n, 2);
        expect(ok, isFalse);
      });
    });

    test('a throwing write is a failure, never an escaping error', () {
      fakeAsync((async) {
        bool? ok;
        playBuzzSequence(
          BuzzSequence(const [0, 300]),
          buzz: () async => throw StateError('link down'),
          isConnected: () => true,
        ).then((v) => ok = v);
        async.elapse(const Duration(seconds: 5));
        expect(ok, isFalse);
      });
    });

    test('not connected at the start: nothing is written', () {
      fakeAsync((async) {
        var n = 0;
        bool? ok;
        playBuzzSequence(
          BuzzSequence(const [0, 300]),
          buzz: () async {
            n++;
            return true;
          },
          isConnected: () => false,
        ).then((v) => ok = v);
        async.elapse(const Duration(seconds: 5));
        expect(n, 0);
        expect(ok, isFalse);
      });
    });
  });

  group('one AlertDispatcher delivery plays the whole sequence', () {
    test('claimed once per (rule, event, target): a re-dispatch plays nothing',
        () {
      fakeAsync((async) {
        var buzzes = 0;
        final seq = BuzzSequence(const [0, 400, 800]);
        final start = DateTime.utc(2026, 10, 2, 9);
        final d = AlertDispatcher(
          phone: () async => false,
          band: () async => false,
          isConnected: () => true,
          ledger: MemoryAlertDeliveryLedger(),
          now: () => start.add(async.elapsed),
        );
        const rule = AlertRule(
          id: 'water',
          kind: 'water',
          destinations: AlertRule.band,
          executionMode: AlertExecutionMode.phoneLive,
          channelPolicyId: 'water',
        );
        Future<bool> play() => playBuzzSequence(seq,
            buzz: () async {
              buzzes++;
              return true;
            },
            isConnected: () => true);
        final outcomes = <AlertDeliveryOutcome>[];
        d
            .dispatch(rule,
                eventId: 'water:1',
                sourceTime: start,
                historical: false,
                bandTransport: play)
            .then(outcomes.add);
        async.elapse(const Duration(seconds: 3));
        d
            .dispatch(rule,
                eventId: 'water:1',
                sourceTime: start.add(const Duration(seconds: 3)),
                historical: false,
                bandTransport: play)
            .then(outcomes.add);
        async.elapse(const Duration(seconds: 3));
        expect(buzzes, 3, reason: 'three steps, one delivery');
        expect(outcomes.first.targets, ['band']);
        expect(outcomes.last.targets, isEmpty);
      });
    });
  });
}
