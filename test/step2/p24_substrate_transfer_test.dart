// P2.4 Substrate adoption (design 02 step 2, B14 and section 4.6).
//
// `derivationPrepareWorker` hands the substrate to the UI isolate through
// `Isolate.exit` (derive_prepare.dart), and its doubles are already
// `Float64List`. The cost left is `Substrate.fromJson` copying every element
// again on the UI isolate, for each substrate a prepare worker returns (up to
// three loads per derived day). `Substrate.fromTransfer(map)` adopts a column
// as is when it already has the right type (`List<int>`, `Float64List`) and
// falls back to the fromJson conversion otherwise, with the SAME normalisation.
// No Int32List, no integer narrowing.
//
// What this file pins (the wiring is in p24_call_sites_test.dart):
//
//   1. equality of every column against `fromJson` (the oracle) for a normal
//      day, a short list, a missing list, an empty substrate and ints beyond
//      32 bits; doubles compared by their bits;
//   2. adoption: the right type is the SAME object, the wrong type is
//      converted and equals fromJson;
//   3. no narrowing: no typed list narrower than the input, 1 << 40 survives;
//   4. end-to-end: the golden day (`two_device_day`) and the day-stream
//      fixture derive byte-identically through fromTransfer, including a map
//      that really crossed `Isolate.run` (which returns through
//      `Isolate.exit`, the worker's own transport).
//
// The oracle's normalisation, read from `Substrate.fromJson` (the code wins
// over the 4.6 prose): a column that is absent OR EMPTY while `ts_sec` has
// rows becomes zeros of that length (`safeI` / `safeD`); a short but NON-empty
// column is kept short; `step_count` and `hr_valid` are different: any length
// other than `ts_sec`'s becomes `-1` of that length; `rr_ts_ms` / `rr_ms` are
// never padded and may differ in length. Tests compare against fromJson, so
// whichever of those the oracle does, fromTransfer must do too.
//
// RED: `Substrate.fromTransfer` is a throwing stub, so every test that calls
// it fails with UnimplementedError('P2.4'). The tests that do not (the oracle
// anchors) pass today and say so.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

import '../support/day_stream_fixture.dart';

// ---------------------------------------------------------------------------
// columns
// ---------------------------------------------------------------------------

const _intKeys = [
  'ts_sec',
  'hr',
  'spo2_red',
  'spo2_ir',
  'skin_temp',
  'skin_contact',
  'step_count',
  'hr_valid',
];
const _dblKeys = ['rr_ts_ms', 'rr_ms', 'ax', 'ay', 'az'];
const _allKeys = [..._intKeys, ..._dblKeys];

List<Object?> _col(Substrate s, String k) => switch (k) {
      'ts_sec' => s.tsSec,
      'hr' => s.hr,
      'spo2_red' => s.spo2Red,
      'spo2_ir' => s.spo2Ir,
      'skin_temp' => s.skinTemp,
      'skin_contact' => s.skinContact,
      'step_count' => s.stepCount,
      'hr_valid' => s.hrValid,
      'rr_ts_ms' => s.rrTsMs,
      'rr_ms' => s.rrMs,
      'ax' => s.ax,
      'ay' => s.ay,
      'az' => s.az,
      _ => throw ArgumentError(k),
    };

List<int> _bits(List<Object?> l) =>
    Float64List.fromList([for (final e in l) e as double])
        .buffer
        .asUint64List()
        .toList();

/// Every column of [got] equals the same column of [want]: ints exactly,
/// doubles by their IEEE-754 bits (so -0.0, NaN and subnormals count).
void _expectSameColumns(Substrate got, Substrate want, String why) {
  for (final k in _allKeys) {
    final g = _col(got, k), w = _col(want, k);
    expect(g.length, w.length, reason: '$why: $k length');
    if (_dblKeys.contains(k)) {
      expect(g, isA<Float64List>(), reason: '$why: $k type');
      expect(_bits(g), orderedEquals(_bits(w)), reason: '$why: $k bits');
    } else {
      expect(g, orderedEquals(w), reason: '$why: $k values');
    }
  }
  expect(got.deviceFamily, want.deviceFamily, reason: '$why: deviceFamily');
  expect(got.deviceIds, want.deviceIds, reason: '$why: deviceIds');
}

/// A typed list narrower than the input could have been: the silent-truncation
/// edge the substrate deliberately avoids.
bool _narrowed(Object? c) =>
    c is Int8List ||
    c is Int16List ||
    c is Int32List ||
    c is Uint8List ||
    c is Uint16List ||
    c is Uint32List ||
    c is Float32List;

// ---------------------------------------------------------------------------
// inputs. Each builder returns a FRESH map (the tests may compare identity).
// ---------------------------------------------------------------------------

const _t0 = 1577923200;

/// What `Substrate.toJson()` delivers across `Isolate.exit`: `List<int>` for
/// the integer columns, `Float64List` for the doubles. Specials in `ax`.
Map<String, dynamic> _normalDay({int n = 64}) {
  List<int> ints(int Function(int) f) => [for (var i = 0; i < n; i++) f(i)];
  Float64List dbls(double Function(int) f) =>
      Float64List.fromList([for (var i = 0; i < n; i++) f(i)]);
  final ax = dbls((i) => 0.01 * i - 0.2);
  final specials = <double>[
    -0.0,
    double.nan,
    double.infinity,
    double.negativeInfinity,
    double.minPositive,
    0.1 + 0.2,
    1e308,
    -1e-7,
  ];
  for (var i = 0; i < specials.length && i < n; i++) {
    ax[i] = specials[i];
  }
  return {
    'ts_sec': ints((i) => _t0 + i),
    'hr': ints((i) => 60 + i % 7),
    'rr_ts_ms': dbls((i) => (_t0 + i) * 1000.0),
    'rr_ms': dbls((i) => 1000.0 - (i % 5) * 10),
    'ax': ax,
    'ay': dbls((i) => 0.5 - 0.003 * i),
    'az': dbls((i) => 1.0 + (i % 3) * 0.125),
    'spo2_red': ints((i) => 1000 + i),
    'spo2_ir': ints((i) => 2000 + i),
    'skin_temp': ints((i) => 30000 + i % 11),
    'skin_contact': ints((i) => i % 2),
    'step_count': ints((i) => i * 3),
    'hr_valid': ints((i) => i % 2),
    'device_family': 'gen5',
    'device_ids': ['dev-b', 'dev-a', 'dev-b'],
  };
}

/// Every list as a `List<dynamic>`: the shape of a `jsonDecode` result (and the
/// wrong type for both column kinds).
Map<String, dynamic> _loosen(Map<String, dynamic> m) => {
      for (final e in m.entries)
        e.key: e.value is List
            ? List<dynamic>.from(e.value as List)
            : e.value,
    };

Map<String, dynamic> _normalDayLoose() {
  final m = _normalDay();
  // NaN and infinity are not JSON; this variant is the jsonDecode shape.
  final ax = m['ax'] as Float64List;
  for (var i = 0; i < 8; i++) {
    ax[i] = 0.25 * i;
  }
  return _loosen(m);
}

/// Doubles delivered as ints and ints delivered as doubles: `jsonDecode` of
/// `1000` and `3.0`. Both must go through num.toDouble / num.toInt.
Map<String, dynamic> _numMixed() => {
      'ts_sec': <dynamic>[_t0, _t0 + 1.0, _t0 + 2],
      'hr': <dynamic>[60.0, 61, 62.0],
      'rr_ts_ms': <dynamic>[1577923200000, 1577923201000.5],
      'rr_ms': <dynamic>[1000, 990.5, 1010],
      'ax': <dynamic>[0, 1, 2.5],
      'ay': <dynamic>[0.0, 0, 1],
      'az': <dynamic>[1, 1, 1],
      'spo2_red': <dynamic>[1.0, 2.0, 3.0],
      'spo2_ir': <dynamic>[4, 5, 6],
      'skin_temp': <dynamic>[30000.0, 30001, 30002],
      'skin_contact': <dynamic>[1, 1, 1.0],
      'step_count': <dynamic>[0.0, 1, 2.0],
      'hr_valid': <dynamic>[1.0, 0, 1],
    };

/// Short lists: a non-empty short column stays short, an empty one becomes
/// zeros, a wrong-length step_count / hr_valid becomes -1, and rr_ts_ms /
/// rr_ms differ in length.
Map<String, dynamic> _shortLists() {
  final m = _normalDay(n: 10);
  return {
    ...m,
    'hr': <int>[61, 62, 63, 64], // non-empty, short
    'ax': Float64List.fromList([0.5, 0.25, 0.125]), // non-empty, short
    'ay': Float64List(0), // empty: zeros
    'spo2_red': <int>[], // empty: zeros
    'step_count': <int>[1, 2, 3, 4, 5, 6, 7], // wrong length: -1s
    'hr_valid': <int>[1, 0], // wrong length: -1s
    'rr_ts_ms': Float64List.fromList([1.5e12, 1.5e12 + 900, 1.5e12 + 1800]),
    'rr_ms': Float64List.fromList([900.0, 905.0]), // not the same length
  };
}

/// Only `ts_sec` present: every other column is missing.
Map<String, dynamic> _onlyTimestamps() => {
      'ts_sec': <int>[for (var i = 0; i < 6; i++) _t0 + i],
    };

/// Some columns present, some missing, step_count present at the right length.
Map<String, dynamic> _someMissing() {
  final m = _normalDay(n: 12);
  return {
    'ts_sec': m['ts_sec'],
    'ax': m['ax'],
    'step_count': m['step_count'],
    'device_family': null,
  };
}

/// Rows in the other columns but no `ts_sec`: n is 0, so nothing is padded and
/// non-empty columns are kept as they come.
Map<String, dynamic> _noTimestamps() {
  final m = _normalDay(n: 5);
  return {for (final e in m.entries) if (e.key != 'ts_sec') e.key: e.value};
}

/// Ints past 32 bits (and past 2^31 on both sides, and the 64-bit extremes).
Map<String, dynamic> _bigInts() {
  const big = <int>[
    1 << 40,
    -(1 << 40),
    1 << 32,
    (1 << 31),
    -(1 << 31) - 1,
    0x7fffffffffffffff,
    -0x8000000000000000,
    (1 << 53) + 1,
  ];
  List<int> col(int shift) => [for (final b in big) b + shift];
  return {
    'ts_sec': col(0),
    'hr': col(1),
    'rr_ts_ms': Float64List.fromList([for (final b in big) b.toDouble()]),
    'rr_ms': Float64List.fromList([for (final b in big) 1.0 * (b >> 20)]),
    'ax': Float64List(big.length),
    'ay': Float64List(big.length),
    'az': Float64List(big.length),
    'spo2_red': col(2),
    'spo2_ir': col(3),
    'skin_temp': col(4),
    'skin_contact': col(5),
    'step_count': col(6),
    'hr_valid': col(7),
  };
}

Map<String, dynamic> _emptySubstrate() => Substrate.empty.toJson();

final _cases = <String, Map<String, dynamic> Function()>{
  'normal day (toJson shape: List<int> + Float64List)': _normalDay,
  'normal day, every list a List<dynamic>': _normalDayLoose,
  'doubles delivered as ints and ints as doubles': _numMixed,
  'short lists': _shortLists,
  'missing lists (only ts_sec)': _onlyTimestamps,
  'missing lists (some present)': _someMissing,
  'no ts_sec at all': _noTimestamps,
  'empty substrate (Substrate.empty.toJson())': _emptySubstrate,
  'empty map': () => <String, dynamic>{},
  'ts_sec empty list': () => {'ts_sec': <int>[]},
  'ints beyond 32 bits': _bigInts,
  'ints beyond 32 bits, as List<dynamic>': () => _loosen(_bigInts()),
};

// ---------------------------------------------------------------------------
// the day fixtures (end-to-end)
// ---------------------------------------------------------------------------

/// The gen4-only rows of test/fixtures/two_device_day.json (regions A, B, E, F
/// of test/two_device_fixture_test.dart, the generator), as the decoded page
/// the prepare worker feeds its accumulator.
Substrate _twoDeviceSubstrate() {
  const dayStart = 1577923200; // 2020-01-02T00:00:00Z
  final frames = <Map<String, dynamic>>[];
  final rrRows = <Map<String, dynamic>>[];
  void region(int from, int toInclusive, {Set<int> holes = const {}}) {
    for (var t = from; t <= toInclusive; t++) {
      if (holes.contains(t)) continue;
      final recTs = dayStart + t;
      frames.add({
        'rec_ts': recTs,
        'device_family': 'gen4',
        'hr': 60 + (recTs % 7),
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'skin_temp_raw': 30000 + (recTs % 11),
      });
      rrRows.add({'rec_ts': recTs, 'rr_ms': 1000 - (recTs % 5) * 10});
    }
  }

  region(0, 2 * 3600 - 1); // A
  region(2 * 3600, 4 * 3600 - 1); // B (gen4 side)
  region(6 * 3600, 6 * 3600 + 1); // E
  region(6 * 3600 + 2, 8 * 3600 - 1,
      holes: {6 * 3600 + 30 * 60, 7 * 3600 + 15 * 60}); // F
  return substrateFromDecodedPage(frames, rrRows);
}

/// The day-stream fixture (test/support/day_stream_fixture.dart): seeded beats
/// with ectopics, gaps and noise, and seeded accelerometer seconds.
Substrate _dayStreamSubstrate() {
  const cfg = SynthBeats(seed: 7);
  return substrateOf(
    synthBeats(cfg),
    synthAccel(7, cfg.startSec, cfg.startSec + cfg.seconds),
  );
}

// Top level so `Isolate.run` can take them: the map comes back through
// `Isolate.exit`, the transport `derivationPrepareWorker` uses.
Map<String, dynamic> _twoDeviceMapFromIsolate() =>
    _twoDeviceSubstrate().toJson();
Map<String, dynamic> _dayStreamMapFromIsolate() =>
    _dayStreamSubstrate().toJson();

/// `_deriveSingleDay` of test/two_device_fixture_test.dart, verbatim in shape:
/// the day's first prepared day through `deriveDayBundle`.
Map<String, dynamic> _derive(Substrate sub) {
  final payload = prepareDerivationPayload(sub);
  expect(payload.days, isNotEmpty, reason: 'a calendar day always exists');
  final day = payload.days.first;
  final daySub = day.daySub;
  final sleepSub = day.sleepSub;
  final input = DayBundleInput(
    date: day.date,
    dayTsSec: daySub.tsSec,
    dayHr: daySub.hr,
    dayRrTsMs: daySub.rrTsMs,
    dayRrMs: daySub.rrMs,
    sleepTsSec: sleepSub.tsSec,
    sleepHr: sleepSub.hr,
    sleepRrTsMs: sleepSub.rrTsMs,
    sleepRrMs: sleepSub.rrMs,
    sleepSkinTemp: sleepSub.skinTemp,
    sleepJson: day.sleepJson,
    hypnoStages: day.hypnoStages,
    sleepOnsetSec: day.sleepOnsetSec,
    sleepOffsetSec: day.sleepOffsetSec,
    profile: const Profile().toMap(),
    dayConfidence: day.confidence,
    dayFlags: day.flags,
    deviceFamily: daySub.deviceFamily,
    sleepSource: day.sleepSource,
  ).toJson();
  return deriveDayBundle(input);
}

void main() {
  group('oracle anchors (pass today: they pin what fromTransfer must equal)',
      () {
    test('fromJson normalises as the header of this file says', () {
      final short = Substrate.fromJson(_shortLists());
      expect(short.length, 10);
      expect(short.hr, [61, 62, 63, 64], reason: 'non-empty short stays short');
      expect(short.ax, hasLength(3));
      expect(short.ay, List<double>.filled(10, 0), reason: 'empty: zeros');
      expect(short.spo2Red, List<int>.filled(10, 0));
      expect(short.stepCount, List<int>.filled(10, -1));
      expect(short.hrValid, List<int>.filled(10, -1));
      expect(short.rrTsMs, hasLength(3));
      expect(short.rrMs, hasLength(2), reason: 'rr lists may differ in length');

      final only = Substrate.fromJson(_onlyTimestamps());
      expect(only.length, 6);
      expect(only.hr, List<int>.filled(6, 0));
      expect(only.ax, List<double>.filled(6, 0));
      expect(only.stepCount, List<int>.filled(6, -1));
      expect(only.hrValid, List<int>.filled(6, -1));
      expect(only.rrMs, isEmpty);

      final empty = Substrate.fromJson(<String, dynamic>{});
      expect(empty.length, 0);
      expect(empty.deviceIds, isEmpty);
      expect(empty.deviceFamily, isNull);
    });

    test('fromJson keeps ints beyond 32 bits', () {
      final s = Substrate.fromJson(_bigInts());
      expect(s.tsSec.first, 1 << 40);
      expect(s.hr[1], (-(1 << 40)) + 1);
      expect(s.tsSec[5], 0x7fffffffffffffff);
    });

    test('Substrate.toJson hands the worker transport typed columns', () {
      final j = Substrate.fromJson(_normalDay()).toJson();
      for (final k in _dblKeys) {
        expect(j[k], isA<Float64List>(), reason: k);
      }
      for (final k in _intKeys) {
        expect(j[k], isA<List<int>>(), reason: k);
        expect(_narrowed(j[k]), isFalse, reason: k);
      }
    });

    test('the two_device fixture rebuilt here derives the committed golden '
        '(so section 4 compares against the right day)', () {
      final tzAtDay = DateTime.fromMillisecondsSinceEpoch(
        1577923200 * 1000,
      ).timeZoneOffset;
      if (tzAtDay != Duration.zero) {
        markTestSkipped('the golden was captured under TZ=UTC');
        return;
      }
      final golden =
          jsonDecode(
                File(
                  'test/fixtures/two_device_day_expected.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;

      final bundle = _derive(_twoDeviceSubstrate());

      expect(jsonEncode(bundle), jsonEncode(golden['single_device']));
    });

    test('both fixtures derive a real bundle, and the fromJson path derives '
        'the same bytes as the substrate itself', () {
      for (final build in [_twoDeviceSubstrate, _dayStreamSubstrate]) {
        final sub = build();
        final direct = jsonEncode(_derive(sub));

        expect(direct.length, greaterThan(1000));
        expect(jsonEncode(_derive(Substrate.fromJson(sub.toJson()))), direct);
      }
    });
  });

  group('1. fromTransfer equals fromJson, column by column', () {
    for (final c in _cases.entries) {
      test(c.key, () {
        final want = Substrate.fromJson(c.value());
        final got = Substrate.fromTransfer(c.value());

        _expectSameColumns(got, want, c.key);
      });
    }

    test('the normal day carries its specials bit for bit (-0.0, NaN, inf, '
        'subnormal, 1e308)', () {
      final got = Substrate.fromTransfer(_normalDay());

      expect(got.ax[0].isNegative, isTrue, reason: '-0.0 keeps its sign');
      expect(got.ax[1].isNaN, isTrue);
      expect(got.ax[2], double.infinity);
      expect(got.ax[3], double.negativeInfinity);
      expect(got.ax[4], double.minPositive);
      expect(got.ax[5], 0.1 + 0.2);
      expect(got.ax[6], 1e308);
    });

    test('device_family and device_ids: absent is null / empty, duplicates '
        'collapse', () {
      final withIds = Substrate.fromTransfer(_normalDay());
      expect(withIds.deviceFamily, 'gen5');
      expect(withIds.deviceIds, {'dev-a', 'dev-b'});

      final without = Substrate.fromTransfer(_onlyTimestamps());
      expect(without.deviceFamily, isNull);
      expect(without.deviceIds, isEmpty);
    });

    test('a missing step_count and hr_valid are the -1 marker, never 0', () {
      final got = Substrate.fromTransfer(_onlyTimestamps());

      expect(got.stepCount, List<int>.filled(6, -1));
      expect(got.hrValid, List<int>.filled(6, -1));
    });

    test('the input map is not modified', () {
      final m = _normalDay();
      final keys = m.keys.toList();
      final before = {for (final e in m.entries) e.key: e.value};

      Substrate.fromTransfer(m);

      expect(m.keys.toList(), keys);
      for (final k in keys) {
        expect(identical(m[k], before[k]), isTrue, reason: k);
      }
    });

    test('a Substrate survives toJson -> fromTransfer with every column '
        'equal', () {
      final src = Substrate.fromJson(_normalDay());
      final got = Substrate.fromTransfer(src.toJson());

      _expectSameColumns(got, src, 'round trip');
    });
  });

  group('2. adoption: the right type is the same object, the wrong type is '
      'converted', () {
    for (final k in _allKeys) {
      test('$k of the right type is adopted (identical, no copy)', () {
        final m = _normalDay();
        final input = m[k];

        final got = Substrate.fromTransfer(m);

        expect(identical(_col(got, k), input), isTrue,
            reason: '$k was copied: ${_col(got, k).runtimeType} vs '
                '${input.runtimeType}');
      });
    }

    test('all 13 columns of a Substrate.toJson() are adopted at once', () {
      final src = Substrate.fromJson(_normalDay());
      final j = src.toJson();

      final got = Substrate.fromTransfer(j);

      for (final k in _allKeys) {
        expect(identical(_col(got, k), j[k]), isTrue, reason: k);
      }
    });

    test('rr_ts_ms and rr_ms of different lengths are both adopted '
        '(never padded)', () {
      final m = _shortLists();

      final got = Substrate.fromTransfer(m);

      expect(identical(got.rrTsMs, m['rr_ts_ms']), isTrue);
      expect(identical(got.rrMs, m['rr_ms']), isTrue);
      expect(got.rrTsMs.length, 3);
      expect(got.rrMs.length, 2);
    });

    test('a Float64List double column of any length (non-empty) is adopted',
        () {
      final m = _shortLists();

      final got = Substrate.fromTransfer(m);

      expect(identical(got.ax, m['ax']), isTrue,
          reason: 'short but non-empty: fromJson keeps it, so it is as is');
    });

    for (final k in _dblKeys) {
      test('$k as a List<dynamic> of doubles is converted to a Float64List '
          'equal to fromJson', () {
        final m = _normalDayLoose();
        final input = m[k];

        final got = Substrate.fromTransfer(m);

        expect(identical(_col(got, k), input), isFalse, reason: k);
        expect(_col(got, k), isA<Float64List>(), reason: k);
        expect(_bits(_col(got, k)),
            orderedEquals(_bits(_col(Substrate.fromJson(_normalDayLoose()), k))),
            reason: k);
      });

      test('$k as a plain List<double> (not a Float64List) is converted to '
          'one', () {
        final m = _normalDay();
        final plain = <double>[for (final e in m[k] as Float64List) e];
        m[k] = plain;

        final got = Substrate.fromTransfer(m);

        expect(identical(_col(got, k), plain), isFalse, reason: k);
        expect(_col(got, k), isA<Float64List>(), reason: k);
        expect(_bits(_col(got, k)), orderedEquals(_bits(plain)), reason: k);
      });
    }

    for (final k in _intKeys) {
      test('$k as a List<dynamic> of ints is converted to a List<int> equal '
          'to fromJson', () {
        final m = _normalDayLoose();
        final input = m[k];

        final got = Substrate.fromTransfer(m);

        expect(identical(_col(got, k), input), isFalse, reason: k);
        expect(_col(got, k), isA<List<int>>(), reason: k);
        expect(_col(got, k),
            orderedEquals(_col(Substrate.fromJson(_normalDayLoose()), k)),
            reason: k);
      });
    }

    test('a mixed map adopts what is typed and converts what is not, in one '
        'call', () {
      final m = _normalDay();
      final tsSec = m['ts_sec'];
      final az = m['az'];
      m['ax'] = List<dynamic>.from(m['ax'] as List);
      m['hr'] = List<dynamic>.from(m['hr'] as List);

      final got = Substrate.fromTransfer(m);

      expect(identical(got.tsSec, tsSec), isTrue);
      expect(identical(got.az, az), isTrue);
      expect(identical(got.ax, m['ax']), isFalse);
      expect(identical(got.hr, m['hr']), isFalse);
      _expectSameColumns(got, Substrate.fromJson(m), 'mixed');
    });

    test('step_count and hr_valid of the wrong length are NOT adopted: -1 '
        'filled', () {
      final m = _normalDay();
      final wrong = <int>[1, 2, 3];
      m['step_count'] = wrong;
      m['hr_valid'] = wrong;

      final got = Substrate.fromTransfer(m);

      expect(identical(got.stepCount, wrong), isFalse);
      expect(identical(got.hrValid, wrong), isFalse);
      expect(got.stepCount, List<int>.filled(64, -1));
      expect(got.hrValid, List<int>.filled(64, -1));
    });

    test('an empty column next to a non-empty ts_sec is not adopted: zeros',
        () {
      final m = _normalDay();
      final emptyInts = <int>[];
      final emptyDbls = Float64List(0);
      m['hr'] = emptyInts;
      m['az'] = emptyDbls;

      final got = Substrate.fromTransfer(m);

      expect(identical(got.hr, emptyInts), isFalse);
      expect(identical(got.az, emptyDbls), isFalse);
      expect(got.hr, List<int>.filled(64, 0));
      expect(got.az, List<double>.filled(64, 0));
    });

    test('a map that crossed Isolate.run (Isolate.exit) arrives typed and is '
        'adopted without a copy', () async {
      final m = await Isolate.run(_twoDeviceMapFromIsolate);
      expect(m['ax'], isA<Float64List>(),
          reason: 'guard: the transport keeps the typed doubles');
      expect(m['ts_sec'], isA<List<int>>());

      final got = Substrate.fromTransfer(m);

      for (final k in _allKeys) {
        expect(identical(_col(got, k), m[k]), isTrue, reason: k);
      }
      _expectSameColumns(got, _twoDeviceSubstrate(), 'worker transport');
    });
  });

  group('3. no narrowing', () {
    for (final c in _cases.entries) {
      test('${c.key}: no column is a narrowed typed list', () {
        final got = Substrate.fromTransfer(c.value());

        for (final k in _allKeys) {
          expect(_narrowed(_col(got, k)), isFalse,
              reason: '$k is ${_col(got, k).runtimeType}');
        }
      });
    }

    test('the integer columns are List<int> and the doubles Float64List on '
        'the conversion path too', () {
      final got = Substrate.fromTransfer(_normalDayLoose());

      for (final k in _intKeys) {
        expect(_col(got, k), isA<List<int>>(), reason: k);
      }
      for (final k in _dblKeys) {
        expect(_col(got, k), isA<Float64List>(), reason: k);
      }
    });

    for (final name in const ['typed (adopted)', 'List<dynamic> (converted)']) {
      test('1 << 40 and the 64-bit extremes survive unchanged: $name', () {
        final m = name.startsWith('typed') ? _bigInts() : _loosen(_bigInts());

        final got = Substrate.fromTransfer(m);

        expect(got.tsSec[0], 1 << 40);
        expect(got.tsSec[1], -(1 << 40));
        expect(got.tsSec[2], 1 << 32);
        expect(got.tsSec[3], 1 << 31);
        expect(got.tsSec[4], -(1 << 31) - 1);
        expect(got.tsSec[5], 0x7fffffffffffffff);
        expect(got.tsSec[6], -0x8000000000000000);
        expect(got.tsSec[7], (1 << 53) + 1,
            reason: 'beyond 2^53: not routed through a double either');
        for (final k in const [
          'hr',
          'spo2_red',
          'spo2_ir',
          'skin_temp',
          'skin_contact',
          'step_count',
          'hr_valid',
        ]) {
          final want = (m[k] as List).cast<int>();
          expect(_col(got, k), orderedEquals(want), reason: k);
          expect(_col(got, k)[0], greaterThan(1 << 39), reason: k);
        }
      });
    }

    test('an int column that arrives as List<int> beyond 32 bits keeps the '
        'very same list', () {
      final m = _bigInts();
      final ts = m['ts_sec'];

      final got = Substrate.fromTransfer(m);

      expect(identical(got.tsSec, ts), isTrue);
      expect(got.tsSec.first, 1 << 40);
    });
  });

  group('4. end-to-end: the day derives byte-identically', () {
    // The existing byte-identical gates are
    // test/two_device_fixture_test.dart (case 1: the golden
    // test/fixtures/two_device_day_expected.json, TZ=UTC) and the
    // day-stream engine tests (test/day_stream_checkpoint_engine_test.dart,
    // which derive through the real prepare worker). Neither can force
    // fromTransfer: the engine has no seam between worker and adoption. These
    // tests feed the SAME fixtures through fromTransfer, directly and across a
    // real Isolate.exit, and compare with the direct derivation.
    final fixtures = <String, ({
      Substrate Function() build,
      Map<String, dynamic> Function() viaIsolate
    })>{
      'two_device_day (gen4 rows)': (
        build: _twoDeviceSubstrate,
        viaIsolate: _twoDeviceMapFromIsolate,
      ),
      'day-stream fixture': (
        build: _dayStreamSubstrate,
        viaIsolate: _dayStreamMapFromIsolate,
      ),
    };

    for (final f in fixtures.entries) {
      test('${f.key}: derive over fromTransfer equals derive over the '
          'substrate (and over fromJson)', () {
        final sub = f.value.build();
        final direct = jsonEncode(_derive(sub));
        expect(direct.length, greaterThan(1000),
            reason: 'guard: the fixture derives a real bundle');

        final adopted = Substrate.fromTransfer(sub.toJson());
        final loose = Substrate.fromTransfer(
            jsonDecode(jsonEncode(sub.toJson())) as Map<String, dynamic>);

        expect(jsonEncode(_derive(adopted)), direct, reason: 'adopted');
        expect(jsonEncode(_derive(loose)), direct,
            reason: 'converted (a jsonDecode map: List<dynamic> everywhere)');
        expect(jsonEncode(_derive(Substrate.fromJson(sub.toJson()))), direct,
            reason: 'the oracle path derives the same');
      });

      test('${f.key}: a map from Isolate.run (the worker transport) derives '
          'the same bytes', () async {
        final direct = jsonEncode(_derive(f.value.build()));

        final m = await Isolate.run(f.value.viaIsolate);
        final got = Substrate.fromTransfer(m);

        expect(jsonEncode(_derive(got)), direct);
        // The oracle is fromJson (it fills an absent step_count / hr_valid with
        // -1), not the built substrate, whose constructor keeps them empty.
        _expectSameColumns(
            got, Substrate.fromJson(f.value.build().toJson()), f.key);
      });
    }

    test('the golden day: derive over fromTransfer is byte-identical to '
        'test/fixtures/two_device_day_expected.json', () async {
      // Same TZ=UTC caveat as the golden's own test (sleepClockOffsetSec).
      final tzAtDay = DateTime.fromMillisecondsSinceEpoch(1577923200 * 1000)
          .timeZoneOffset;
      if (tzAtDay != Duration.zero) {
        markTestSkipped('the golden was captured under TZ=UTC; run with '
            'TZ=UTC (current offset: $tzAtDay)');
        return;
      }
      final golden = jsonDecode(File('test/fixtures/two_device_day_expected.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final m = await Isolate.run(_twoDeviceMapFromIsolate);

      final bundle = _derive(Substrate.fromTransfer(m));

      expect(jsonEncode(bundle), jsonEncode(golden['single_device']),
          reason: 'fromTransfer must not move a number. Do NOT regenerate '
              'the golden to make this pass.');
    });
  });
}
