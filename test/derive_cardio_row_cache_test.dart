// Round 17: the cardio row cache in edge staging (exact, no output change).
//
// `prepareSleepSessionCandidate` / `prepareDerivationPayload` / `calendarDays`
// take an optional `CardioRowCache? rowCache` and hand it to every
// `segmentSleep` call. Null is today's behaviour; a cache must change nothing
// about the output (byte-identical JSON) and only turn repeat work into hits.
//
// RED until the `rowCache` parameter exists. Engine-level wiring (the main
// isolate cache, window restriction, pruning, perf counters) is the green
// phase's and is not pinned here.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';

/// Fixed calendar so the test does not depend on "today".
final DateTime _mid = DateTime(2026, 6, 27);
const String _day = '2026-06-27';
const String _nextDay = '2026-06-28';

int _h(double hours, {DateTime? from}) =>
    (from ?? _mid)
        .add(Duration(minutes: (hours * 60).round()))
        .millisecondsSinceEpoch ~/
    1000;

/// 1 Hz HR + gravity AND beat-to-beat RR over `[from, to)` hours past [base],
/// asleep (still, low HR, slow breathing-modulated RR) where [asleep] says so.
/// Beats are what put staging on the cardio path, so they are not optional.
Substrate _build(
  double from,
  double to,
  bool Function(int) asleep, {
  DateTime? base,
}) {
  final b = base ?? _mid;
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  final rrTs = <double>[], rr = <double>[];
  var nextBeatMs = _h(from, from: b) * 1000.0;
  for (var t = _h(from, from: b); t < _h(to, from: b); t++) {
    final s = asleep(t);
    final bpm = s ? 52 + (t % 7) : 80 + (t ~/ 60) % 20 + t % 3;
    ts.add(t);
    hr.add(bpm);
    ax.add(s ? 0.0 : .3 * math.sin(t * .21));
    ay.add(s ? 0.0 : .2 * math.cos(t * .13));
    az.add(s ? 1.0 : 1 + .05 * math.sin(t * .07));
    while (nextBeatMs < (t + 1) * 1000.0) {
      final ibi = 60000.0 / bpm + (s ? 40 : 12) * math.sin(t * (s ? .35 : .9));
      rrTs.add(nextBeatMs);
      rr.add(ibi);
      nextBeatMs += ibi;
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: rrTs,
    rrMs: rr,
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List.filled(ts.length, 1),
    spo2Ir: List.filled(ts.length, 1),
    skinTemp: List.filled(ts.length, 3000),
    skinContact: List.filled(ts.length, 1),
    deviceFamily: 'gen4',
  );
}

// Asleep 23:00 (day before) to 06:00 on [_day].
bool _night(int t) => t >= _h(-1) && t < _h(6);

// A second night, 23:00 on [_day] to 06:00 on [_nextDay].
bool _twoNights(int t) =>
    _night(t) || (t >= _h(23) && t < _h(30));

String _json(SleepSessionCandidate c) => jsonEncode(c.toJson());

void main() {
  group('rowCache through the real prepare path', () {
    test('a cached run is byte-identical to the uncached run (candidate and '
        'observation JSON), and a null cache is today\'s behaviour', () {
      final sub = _build(-2, 7, _night);

      final plain = prepareSleepSessionCandidate(sub, targetDay: _day);
      expect(plain.present, isTrue, reason: 'guard: the fixture stages a night');
      final plainObs = jsonEncode(
        prepareDerivationPayload(sub, targetDay: _day).days.first.sleepJson,
      );

      final nullCache = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        rowCache: null,
      );
      expect(_json(nullCache), _json(plain));

      final cache = ana.CardioRowCache();
      final cold = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        rowCache: cache,
      );
      expect(_json(cold), _json(plain), reason: 'a cold cache changes nothing');
      expect(cache.length, greaterThan(0), reason: 'the run filled the cache');

      final obsCache = ana.CardioRowCache();
      for (var i = 0; i < 2; i++) {
        final obs = jsonEncode(
          prepareDerivationPayload(
            sub,
            targetDay: _day,
            rowCache: obsCache,
          ).days.first.sleepJson,
        );
        expect(obs, plainObs, reason: 'observation JSON, pass $i');
      }
    });

    test('staging the same day twice: the second run hits, never misses', () {
      final sub = _build(-2, 7, _night);
      final plain = prepareSleepSessionCandidate(sub, targetDay: _day);

      final cache = ana.CardioRowCache();
      final first = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        rowCache: cache,
      );
      expect(cache.misses, greaterThan(0), reason: 'a cold pass computes rows');
      final rows = cache.length;

      cache.hits = 0;
      cache.misses = 0;
      final second = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        rowCache: cache,
      );
      expect(_json(first), _json(plain));
      expect(_json(second), _json(plain));
      expect(cache.hits, greaterThan(0));
      expect(cache.misses, 0, reason: 'unchanged data: every row is a hit');
      expect(cache.length, rows, reason: 'nothing new to store');
    });

    test('a night that grows between passes reuses the rows it already had', () {
      final partial = _build(-2, 3, _night);
      final full = _build(-2, 7, _night);
      final plainFull = prepareSleepSessionCandidate(full, targetDay: _day);

      final cache = ana.CardioRowCache();
      prepareSleepSessionCandidate(partial, targetDay: _day, rowCache: cache);
      cache.hits = 0;
      cache.misses = 0;
      final grown = prepareSleepSessionCandidate(
        full,
        targetDay: _day,
        rowCache: cache,
      );
      expect(_json(grown), _json(plainFull));
      expect(cache.hits, greaterThan(0), reason: 'the first 3 h were cached');
    });

    test('D then D+1 shares one cache and each day equals its uncached self',
        () {
      final sub = _build(-2, 31, _twoNights);
      final plainD = prepareSleepSessionCandidate(sub, targetDay: _day);
      final plainD1 = prepareSleepSessionCandidate(sub, targetDay: _nextDay);
      expect(plainD.present, isTrue);
      expect(plainD1.present, isTrue);

      final cache = ana.CardioRowCache();
      final d = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        rowCache: cache,
      );
      final afterD = cache.length;
      final d1 = prepareSleepSessionCandidate(
        sub,
        targetDay: _nextDay,
        rowCache: cache,
      );
      expect(_json(d), _json(plainD));
      expect(_json(d1), _json(plainD1));
      expect(cache.length, greaterThanOrEqualTo(afterD),
          reason: 'D+1 adds rows, it does not evict D\'s');

      // Order must not matter: D+1 first, then D, same bytes.
      final rev = ana.CardioRowCache();
      final r1 = prepareSleepSessionCandidate(
        sub,
        targetDay: _nextDay,
        rowCache: rev,
      );
      final r0 = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        rowCache: rev,
      );
      expect(_json(r1), _json(plainD1));
      expect(_json(r0), _json(plainD));
      expect(rev.length, cache.length, reason: 'same rows in either order');
    });

    test('a user-window override stages through the cache identically', () {
      final sub = _build(-2, 7, _night);
      final ov = SleepWindowOverride(
        dayId: _day,
        onsetSec: _h(0),
        offsetSec: _h(5),
        source: 'confirmed',
      );
      final plain = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        override: ov,
      );
      final cache = ana.CardioRowCache();
      for (var i = 0; i < 2; i++) {
        final got = prepareSleepSessionCandidate(
          sub,
          targetDay: _day,
          override: ov,
          rowCache: cache,
        );
        expect(_json(got), _json(plain), reason: 'override pass $i');
      }
      expect(cache.hits, greaterThan(0), reason: 'the forced window hits too');
    });

    test('calendarDays takes the cache and returns the same days', () {
      final sub = _build(-2, 7, _night);
      final plain = calendarDays(sub);
      final cache = ana.CardioRowCache();
      final got = calendarDays(sub, rowCache: cache);
      expect(got.map((d) => d.date), plain.map((d) => d.date));
      expect(
        got.map((d) => jsonEncode(d.sleep.toJson())).toList(),
        plain.map((d) => jsonEncode(d.sleep.toJson())).toList(),
      );
      expect(cache.length, greaterThan(0));
    });

    test('a malformed cache payload falls back to empty, output unchanged', () {
      final sub = _build(-2, 7, _night);
      final plain = prepareSleepSessionCandidate(sub, targetDay: _day);

      // What the isolate does with plain data it was handed: decode, and on a
      // FormatException start empty (refuse, never guess).
      ana.CardioRowCache decodeOrEmpty(Map<String, dynamic> json) {
        try {
          return ana.CardioRowCache.fromJson(json);
        } on FormatException {
          return ana.CardioRowCache();
        }
      }

      final bad = <Map<String, dynamic>>[
        {'version': 99, 'rows': <Object?>[]},
        {'version': 1, 'rows': 'nope'},
        {
          'version': 1,
          'rows': [
            {'startSec': 1, 'epochSec': 0, 'fingerprint': '1'},
          ],
        },
      ];
      for (final payload in bad) {
        final cache = decodeOrEmpty(payload);
        expect(cache.length, 0);
        final got = prepareSleepSessionCandidate(
          sub,
          targetDay: _day,
          rowCache: cache,
        );
        expect(_json(got), _json(plain));
      }
    });

    test('a cache that went through JSON gives the same bytes and hits', () {
      final sub = _build(-2, 7, _night);
      final plain = prepareSleepSessionCandidate(sub, targetDay: _day);
      final warm = ana.CardioRowCache();
      prepareSleepSessionCandidate(sub, targetDay: _day, rowCache: warm);

      // The isolate seam: plain data in, plain data out.
      final wire = jsonDecode(jsonEncode(warm.toJson())) as Map<String, dynamic>;
      final decoded = ana.CardioRowCache.fromJson(wire);
      expect(decoded.length, warm.length);
      final got = prepareSleepSessionCandidate(
        sub,
        targetDay: _day,
        rowCache: decoded,
      );
      expect(_json(got), _json(plain));
      expect(decoded.hits, greaterThan(0));
      expect(decoded.misses, 0);
    });
  });
}
