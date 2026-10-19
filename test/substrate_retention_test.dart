// The seam that makes a warm pass exact: a substrate built from a retained
// prefix plus the rows from the cut on is the one a cold load builds, down to
// the substrate-wide singletons (family, device ids, skin-temperature unit) and
// the beat axis, for every combination of beat start the engine can ask for.
// (The engine end of it is test/warm_substrate_reuse_test.dart.)
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart'
    show kRevBucketSec;
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/substrate_retention.dart';
import 'package:openstrap_edge/data/coverage_resolver.dart';

typedef _Page = ({
  List<Map<String, dynamic>> frames,
  List<Map<String, dynamic>> rr
});

const _span = 5 * kRevBucketSec;
final _base = (1700000000 ~/ kRevBucketSec) * kRevBucketSec;

/// One scenario's world: which seconds have a frame, a beat, which temperature
/// column and family, so each singleton rule has something to decide.
class _World {
  _World({required this.tempFromBucket, required this.gen5FromBucket});

  /// Rows before this bucket carry no skin temperature at all.
  final int tempFromBucket;

  /// Rows from this bucket on are stamped gen5 (and a second device id).
  final int gen5FromBucket;

  int _bucket(int s) => (s - _base) ~/ kRevBucketSec;

  Map<String, dynamic>? frame(int s) {
    if (s % 97 == 0) return null; // a beat-only second (no 1 Hz row)
    final b = _bucket(s);
    final temp = b >= tempFromBucket;
    // The first temperature seen picks the unit; later rows in the other unit
    // read as absent.
    final asC = b == tempFromBucket || b == tempFromBucket + 2;
    return {
      'rec_ts': s,
      'counter': s,
      'hr': 50 + s % 40,
      'ax': 0.1 + (s % 7) / 10,
      'ay': 0.2,
      'az': 0.9,
      'spo2_red_raw': 100 + s % 5,
      'spo2_ir_raw': 200 + s % 5,
      'skin_temp_raw': temp && !asC ? 30000 + s % 50 : null,
      'skin_temp_c': temp && asC ? 33.0 + (s % 9) / 10 : null,
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
          // Every 11th second's first beat is placed BEFORE the last one of
          // the second before: the axis steps backwards, which is repaired by
          // a running maximum that must not start over at the cut.
          'beat_ts_ms': s % 11 == 0 && i == 0 ? s * 1000 - 1500 : s * 1000 - i * 400,
          'rr_ms': s % 13 == 0 && i == 0 ? 100 : 700.0 + s % 90,
          'device_id': '',
        },
    ];
  }

  /// The pages of rows `[from, to)` a loader sends, beats read from [low] on
  /// (null: every beat) and, below it, one slot per second that has beats.
  List<_Page> pages(int from, int to, {int? low, int? beatsFrom}) {
    final out = <_Page>[];
    for (var a = from; a < to; a += 700) {
      final b = a + 700 < to ? a + 700 : to;
      final frames = <Map<String, dynamic>>[];
      final rr = <Map<String, dynamic>>[];
      for (var s = a; s < b; s++) {
        final f = frame(s);
        if (f != null) frames.add(f);
        if (low != null && s < low) {
          if (beats(s).isNotEmpty) rr.add({'rec_ts': s, 'device_id': ''});
        } else {
          rr.addAll(beats(s));
        }
      }
      out.add((frames: frames, rr: rr));
    }
    return out;
  }
}

Map<String, Object?> _norm(({Substrate sub, Map<String, Object?> extras}) r) {
  final j = r.sub.toJson();
  return {
    ...j,
    'device_ids': (j['device_ids'] as List).cast<String>().toList()..sort(),
    'rr_start': r.extras['rr_start'],
    'rr_ts_raw': r.extras['rr_ts_raw'],
    'meta': [
      for (final m in r.extras['meta'] as List)
        [
          (m as List)[0],
          ((m[1] as List).cast<String>().toList()..sort()),
          ((m[2] as List).cast<String>().toList()..sort()),
          m[3],
        ],
    ],
  };
}

RetainedLoad _retained(({Substrate sub, Map<String, Object?> extras}) r,
    {int? rrFrom, required int cut}) =>
    RetainedLoad(
      from: _base,
      to: _base + _span,
      rrFrom: rrFrom,
      revs: const {},
      ownership: const {},
      multiOwner: false,
      generation: (wipeEpoch: 0, openCount: 0),
      cut: cut,
      sub: r.sub,
      rrStart: r.extras['rr_start'] as Int32List,
      rrTsRaw: r.extras['rr_ts_raw'] as Float64List,
      meta: [
        for (final w in r.extras['meta'] as List)
          BucketMeta.fromWire((w as List).cast<Object?>()),
      ],
    );

void main() {
  // (beats the previous load held from, beats this load wants from,
  //  can the seed's beats be kept?)
  final cases = <(String, int?, int?, bool)>[
    ('all beats both times', null, null, true),
    ('later beat start, inside the kept part', null, 1500, true),
    ('later beat start, past the cut', null, 3200, true),
    ('both start late, the later one drops beats', 500, 2000, true),
    ('earlier start than held: beats read again', 2000, 600, false),
    ('every beat wanted, a late start held: read again', 500, null, false),
  ];
  final worlds = <String, _World>{
    'unit set in the kept part, second family later':
        _World(tempFromBucket: 0, gen5FromBucket: 3),
    'unit first seen after the cut': _World(tempFromBucket: 3, gen5FromBucket: 9),
    'no temperature, family changes inside the kept part':
        _World(tempFromBucket: 9, gen5FromBucket: 1),
  };

  for (final w in worlds.entries) {
    for (final c in cases) {
      test('${w.key}: ${c.$1}', () {
        final world = w.value;
        final lowA = c.$2 == null ? null : _base + c.$2!;
        final lowB = c.$3 == null ? null : _base + c.$3!;
        // The previous pass saw rows up to the middle of bucket 3.
        final seen = _base + 3 * kRevBucketSec + 400;
        final prev = accumulateRetained(
            pages: world.pages(_base, seen, low: lowA));
        final cut = ((seen - 1) ~/ kRevBucketSec) * kRevBucketSec;
        final load = _retained(prev, rrFrom: lowA, cut: cut);
        // A reuse of the load is what the engine decides; here it is given.
        expect(
          load.reuse(
            from: _base,
            to: _base + _span,
            rrFrom: lowB,
            // Only the open bucket moved: rows were added to it.
            revs: {cut ~/ kRevBucketSec: 1},
            ownership: {for (final s in kExclusiveOwnershipSignals) s: <OwnedSpan>[]},
            multiOwner: false,
            generation: (wipeEpoch: 0, openCount: 0),
          ),
          (cut: cut, keepBeats: c.$4),
          reason: 'the engine reads rows from the open bucket, beats ${c.$4}',
        );

        // Rows after the previous pass land too; the cold load sees all.
        final end = _base + _span;
        final cold = accumulateRetained(pages: world.pages(_base, end, low: lowB));

        final tailFrom = cut;
        final warm = accumulateRetained(
          seed: load.seedMessage(cut, lowB, c.$4),
          prefixBeats: c.$4
              ? const []
              : [
                  for (var s = lowB ?? _base; s < cut; s++) ...world.beats(s),
                ],
          // Beats of the tail from the cut on, the way `_loadSubstrateRange`
          // reads them (slots below the start, beats from it).
          pages: world.pages(tailFrom, end, low: lowB),
        );
        expect(_norm(warm), equals(_norm(cold)));
      });
    }
  }
}
