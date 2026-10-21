// The cross-day union's two cuts (substrate_retention.dart): a window cut out
// of a bigger load, and a load joined from parts, are the load a cold read of
// that range builds, down to the beat axis (its running maximum restarts at the
// window's first beat, and runs on across a seam), where each second's beats
// start, and the substrate-wide singletons. Where they cannot be exact (a
// window over two families or units) they refuse, and the engine reads it from
// the database as before. The engine end is test/substrate_single_load_test.dart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart'
    show kRevBucketSec;
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate_retention.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/coverage_resolver.dart';

typedef _Page = ({
  List<Map<String, dynamic>> frames,
  List<Map<String, dynamic>> rr
});

const _span = 6 * kRevBucketSec;
final _base = (1700000000 ~/ kRevBucketSec) * kRevBucketSec;
const _gen = (wipeEpoch: 0, openCount: 0);
final _own = {for (final s in kExclusiveOwnershipSignals) s: <OwnedSpan>[]};

class _World {
  _World({this.gen5FromBucket = 99, this.mixedUnits = false});

  /// Rows from this bucket on are stamped gen5 (and a second device id).
  final int gen5FromBucket;

  /// Buckets 1 and 3 carry centi-degrees, the rest a raw count: the first
  /// unit seen picks, the other reads as absent.
  final bool mixedUnits;

  int _bucket(int s) => (s - _base) ~/ kRevBucketSec;

  Map<String, dynamic>? frame(int s) {
    if (s % 97 == 0) return null; // a beat-only second (no 1 Hz row)
    final b = _bucket(s);
    final asC = mixedUnits && (b == 1 || b == 3);
    return {
      'rec_ts': s,
      'counter': s,
      'hr': 50 + s % 40,
      'ax': 0.1 + (s % 7) / 10,
      'ay': 0.2,
      'az': 0.9,
      'spo2_red_raw': 100 + s % 5,
      'spo2_ir_raw': 200 + s % 5,
      'skin_temp_raw': !asC ? 30000 + s % 50 : null,
      'skin_temp_c': asC ? 33.0 + (s % 9) / 10 : null,
      'step_count': s % 2 == 0 ? s % 1000 : null,
      'hr_valid': s % 5 == 0 ? 1 : null,
      'band_sleep_state': s % 3 == 0 ? 2 : null,
      'device_family': b >= gen5FromBucket ? 'gen5' : 'gen4',
      'device_id': b >= gen5FromBucket && s % 2 == 0 ? 'ring-A' : '',
    };
  }

  List<Map<String, dynamic>> beats(int s) {
    if (s % 3 == 0) return const [];
    return [
      for (var i = 0; i < 1 + s % 2; i++)
        {
          'rec_ts': s,
          'beat_index': i,
          'rr_ts_ms': s * 1000,
          // Every 11th second's first beat is placed BEFORE the last beat of
          // the second before, and every 17th by far more: the axis steps
          // back, and the repair is a running maximum that must restart at a
          // window's first beat and run on over a seam.
          'beat_ts_ms': s % 11 == 0 && i == 0
              ? s * 1000 - 1500
              : s % 17 == 0 && i == 0
                  ? s * 1000 - 9000
                  : s * 1000 - i * 400,
          'rr_ms': s % 13 == 0 && i == 0 ? 100 : 700.0 + s % 90,
          'device_id': '',
        },
    ];
  }

  /// The pages a loader sends for the seconds `[a, b]` (inclusive).
  List<_Page> pages(int a, int b) {
    final out = <_Page>[];
    for (var x = a; x <= b; x += 700) {
      final y = x + 699 < b ? x + 699 : b;
      final frames = <Map<String, dynamic>>[];
      final rr = <Map<String, dynamic>>[];
      for (var s = x; s <= y; s++) {
        final f = frame(s);
        if (f != null) frames.add(f);
        rr.addAll(beats(s));
      }
      out.add((frames: frames, rr: rr));
    }
    return out;
  }

  /// A cold load of `[a, b]`.
  RetainedLoad cold(int a, int b) {
    final r = accumulateRetained(pages: pages(a, b));
    final last = r.sub.isEmpty ? null : r.sub.tsSec.last;
    return RetainedLoad(
      from: a,
      to: b,
      rrFrom: null,
      revs: const {},
      ownership: _own,
      multiOwner: false,
      generation: _gen,
      cut: last == null ? a : (last ~/ kRevBucketSec) * kRevBucketSec,
      sub: r.sub,
      rrStart: r.extras['rr_start'] as Int32List,
      rrTsRaw: r.extras['rr_ts_raw'] as Float64List,
      meta: [
        for (final w in r.extras['meta'] as List)
          BucketMeta.fromWire((w as List).cast<Object?>()),
      ],
    );
  }
}

Map<String, Object?> _norm(RetainedLoad l) {
  final j = l.sub.toJson();
  return {
    ...j,
    'device_ids': (j['device_ids'] as List).cast<String>().toList()..sort(),
    'rr_start': l.rrStart.toList(),
    'rr_ts_raw': l.rrTsRaw.toList(),
    'meta': [
      for (final m in l.meta)
        [
          m.bucket,
          m.families.toList()..sort(),
          m.deviceIds.toList()..sort(),
          m.skinUnit,
        ],
    ],
  };
}

/// The first second at or after `_base + 1000` that a world gives an
/// inverted first beat (a multiple of [n]).
int _nextMultiple(int n) {
  var s = _base + 1000;
  while (s % n != 0) {
    s++;
  }
  return s;
}

void main() {
  final end = _base + _span - 1;

  group('a window cut from a bigger load is a load of that window', () {
    final world = _World();
    final big = world.cold(_base, end);
    // (from, to): on bucket edges, off them, around inversions (s % 11 == 0
    // and s % 17 == 0 first beats), and over a hole.
    final windows = <(String, int, int)>[
      ('whole range', _base, end),
      ('bucket edges', _base + kRevBucketSec, _base + 3 * kRevBucketSec - 1),
      ('off the edges', _base + 1234, _base + 3 * kRevBucketSec + 777),
      for (final s in [_nextMultiple(11), _nextMultiple(17), _nextMultiple(187)])
        ('starts on $s', s, s + 1500),
      ('one second', _base + 2000, _base + 2000),
      ('a beat-only second', _base + 97 * 12, _base + 97 * 12 + 40),
    ];
    for (final w in windows) {
      test(w.$1, () {
        final cut = big.windowHeavy(w.$2, w.$3, ownership: _own, multiOwner: false);
        expect(cut, isNotNull);
        expect(_norm(cut!), equals(_norm(world.cold(w.$2, w.$3))));
      });
    }

    test('a window outside the load is refused', () {
      expect(big.windowHeavy(_base - 5, _base + 100, ownership: _own, multiOwner: false),
          isNull);
      expect(big.windowHeavy(_base, end + 1, ownership: _own, multiOwner: false),
          isNull);
    });

    test('another owner over the window is refused', () {
      final other = {
        for (final s in kExclusiveOwnershipSignals)
          s: [(start: _base, end: end + 1, deviceId: 'ring-A')],
      };
      expect(big.windowHeavy(_base + 10, _base + 900, ownership: other, multiOwner: false),
          isNull);
      expect(big.windowHeavy(_base + 10, _base + 900, ownership: _own, multiOwner: true),
          isNull);
    });
  });

  group('parts joined are the load of their range', () {
    final world = _World();
    final splits = <int>[
      _base + 500,
      _nextMultiple(11), // a first beat before the last one of the second before
      _nextMultiple(17), // one far back
      _base + 2 * kRevBucketSec - 1,
      _base + 2 * kRevBucketSec,
      end - 3,
    ];
    for (final m in splits) {
      test('split after $m', () {
        final joined = RetainedLoad.joinHeavy(
          [world.cold(_base, m), world.cold(m + 1, end)],
          revs: const {},
          ownership: _own,
          multiOwner: false,
          generation: _gen,
        );
        expect(joined, isNotNull);
        expect(_norm(joined!), equals(_norm(world.cold(_base, end))));
        expect(joined.from, _base);
        expect(joined.to, end);
      });
    }

    test('three parts, one of them a window cut out of a bigger load', () {
      final big = world.cold(_base, end);
      final mid = big.windowHeavy(_base + 900, _base + 2500,
          ownership: _own, multiOwner: false)!;
      final joined = RetainedLoad.joinHeavy(
        [world.cold(_base, _base + 899), mid, world.cold(_base + 2501, end)],
        revs: const {},
        ownership: _own,
        multiOwner: false,
        generation: _gen,
      );
      expect(_norm(joined!), equals(_norm(big)));
    });

    test('parts that do not meet do not join', () {
      expect(
        RetainedLoad.joinHeavy(
          [world.cold(_base, _base + 99), world.cold(_base + 101, end)],
          revs: const {},
          ownership: _own,
          multiOwner: false,
          generation: _gen,
        ),
        isNull,
      );
    });
  });

  group('what is not exact is refused', () {
    test('a window over two families', () {
      final world = _World(gen5FromBucket: 2);
      final big = world.cold(_base, end);
      expect(
          big.windowHeavy(_base + kRevBucketSec, _base + 3 * kRevBucketSec,
              ownership: _own, multiOwner: false),
          isNull);
      // ...but one that stays on the first family, with a single device, is not.
      final cut = big.windowHeavy(_base + 10, _base + kRevBucketSec * 2 - 1,
          ownership: _own, multiOwner: false);
      expect(cut, isNotNull);
      expect(_norm(cut!),
          equals(_norm(world.cold(_base + 10, _base + kRevBucketSec * 2 - 1))));
    });

    test('a window whose unit is not the one the load picked', () {
      final world = _World(mixedUnits: true);
      final big = world.cold(_base, end);
      // Bucket 3 is centi-degrees in a load whose first temperature was a raw
      // count: its rows read as absent in the big load, present in a load that
      // starts there.
      expect(
          big.windowHeavy(_base + 3 * kRevBucketSec, _base + 4 * kRevBucketSec - 1,
              ownership: _own, multiOwner: false),
          isNull);
    });

    test('parts that picked different units do not join', () {
      final world = _World(mixedUnits: true);
      expect(
          RetainedLoad.joinHeavy(
            [
              world.cold(_base + 3 * kRevBucketSec, _base + 4 * kRevBucketSec - 1),
              world.cold(_base + 4 * kRevBucketSec, end),
            ],
            revs: const {},
            ownership: _own,
            multiOwner: false,
            generation: _gen,
          ),
          isNull);
    });
  });

  group('which stretches of a load a new range can use', () {
    final world = _World();
    RetainedLoad load(int a, int b, Map<int, int> revs) => RetainedLoad(
          from: a,
          to: b,
          rrFrom: null,
          revs: revs,
          ownership: _own,
          multiOwner: false,
          generation: _gen,
          cut: a,
          sub: world.cold(a, b).sub,
          rrStart: Int32List(0),
          rrTsRaw: Float64List(0),
          meta: const [],
        );
    List<(int, int)> use(List<RetainedLoad> bases, int from, int to,
            Map<int, int> revs,
            {Map<InputSignal, List<OwnedSpan>>? ownership,
            bool multiOwner = false,
            ({int wipeEpoch, int openCount}) generation = _gen}) =>
        [
          for (final s in usableStretches(bases,
              from: from,
              to: to,
              revs: revs,
              ownership: ownership ?? _own,
              multiOwner: multiOwner,
              generation: generation))
            (s.a, s.b)
        ];

    test('the overlap, when nothing moved', () {
      final a = load(_base, _base + 3 * kRevBucketSec - 1, const {});
      expect(use([a], _base + kRevBucketSec, end, const {}),
          [(_base + kRevBucketSec, _base + 3 * kRevBucketSec - 1)]);
    });

    test('not the buckets whose revision moved', () {
      final a = load(_base, end, const {});
      final b1 = _base ~/ kRevBucketSec + 2;
      expect(use([a], _base, end, {b1: 4}), [
        (_base, _base + 2 * kRevBucketSec - 1),
        (_base + 3 * kRevBucketSec, end),
      ]);
    });

    test('of two bases the one that reaches further', () {
      final a = load(_base, _base + 2 * kRevBucketSec, const {});
      final b = load(_base + kRevBucketSec, end, const {});
      expect(use([a, b], _base, end, const {}), [
        (_base, _base + 2 * kRevBucketSec),
        (_base + 2 * kRevBucketSec + 1, end),
      ]);
    });

    test('nothing of a base under other owners, other generation, other mode', () {
      final a = load(_base, end, const {});
      final other = {
        for (final s in kExclusiveOwnershipSignals)
          s: [(start: _base, end: end + 1, deviceId: 'ring-A')],
      };
      expect(use([a], _base, end, const {}, ownership: other), isEmpty);
      expect(use([a], _base, end, const {}, multiOwner: true), isEmpty);
      expect(use([a], _base, end, const {}, generation: (wipeEpoch: 1, openCount: 0)),
          isEmpty);
    });
  });
}
