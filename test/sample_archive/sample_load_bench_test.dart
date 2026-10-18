// DEV-ONLY harness: load-time comparison on a REAL export.
//
//   OPENSTRAP_REAL_DB=/path/to/openstrap_export.db \
//   TZ=UTC flutter test test/sample_archive/sample_load_bench_test.dart
//
// Skipped when OPENSTRAP_REAL_DB is unset. Read-only; prints timings and byte
// counts only, never a sample value. Timings are from the machine running the
// test (a desktop is several times faster than a phone): compare the RATIOS,
// not the absolute numbers.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/sample_codec.dart';

const _days = ['2026-10-03', '2026-10-04'];
const _accel = ['ax', 'ay', 'az'];
const _runs = 7;

/// Median wall time of [runs] calls after two un-timed warm-ups.
Future<double> _medianMs(Future<void> Function() f, {int runs = _runs}) async {
  await f();
  await f();
  final ts = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await f();
    sw.stop();
    ts.add(sw.elapsedMicroseconds / 1000);
  }
  ts.sort();
  return ts[ts.length ~/ 2];
}

void main() {
  final path = Platform.environment['OPENSTRAP_REAL_DB'];

  test('real export: day load times, raw rows vs archive', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(path!,
        options: OpenDatabaseOptions(readOnly: true));
    final out = <String>[
      '| day | load | median ms | bytes read |',
      '|---|---|---|---|',
    ];
    try {
      for (final day in _days) {
        final t0 = DateTime.parse('${day}T00:00:00Z').millisecondsSinceEpoch ~/ 1000;
        // 1. Raw: the five columns for one day, as a chart would read them.
        late List<Map<String, Object?>> rows;
        final rawMs = await _medianMs(() async {
          rows = await db.rawQuery(
              'SELECT rec_ts, hr, ax, ay, az, skin_temp_c FROM decoded_onehz '
              'WHERE rec_ts >= ? AND rec_ts < ? ORDER BY rec_ts',
              [t0, t0 + 86400]);
        });
        out.add('| $day | raw SQL rows (5 signals, 1 Hz) | ${rawMs.toStringAsFixed(1)} | ${rows.length} rows |');

        // Slots for encoding (not timed).
        List<double?> slots(String col) {
          final v = List<double?>.filled(86400, null);
          for (final r in rows) {
            final x = r[col] as num?;
            if (x == null || (col == 'hr' && x <= 0)) continue;
            v[(r['rec_ts'] as int) - t0] = x.toDouble();
          }
          return v;
        }

        final blobs = <String, Uint8List>{
          'hr': SampleCodec.encode('hr', slots('hr'), mode: SampleMode.quantized).blob,
          'skin_temp_c': SampleCodec.encode('skin_temp_c', slots('skin_temp_c'),
                  mode: SampleMode.quantized)
              .blob,
          for (final a in _accel)
            a: SampleCodec.encode(a, slots(a), mode: SampleMode.pyramidOnly).blob,
        };
        final dct = <String, Uint8List>{
          'hr': SampleCodec.encode('hr', slots('hr')).blob,
          'skin_temp_c': SampleCodec.encode('skin_temp_c', slots('skin_temp_c')).blob,
        };
        final archBytes = blobs.values.fold<int>(0, (s, b) => s + b.length);

        // 2. Archive, full detail: decode hr + temp samples, accel summaries.
        final fullMs = await _medianMs(() async {
          SampleCodec.decode(blobs['hr']!);
          SampleCodec.decode(blobs['skin_temp_c']!);
          for (final a in _accel) {
            SampleCodec.summary(blobs[a]!);
          }
        });
        out.add('| $day | archive, full detail (hr+temp samples, accel minute envelope) | ${fullMs.toStringAsFixed(1)} | $archBytes B |');

        // 3. Old DCT (codec v1), full detail, for comparison.
        final dctMs = await _medianMs(() async {
          SampleCodec.decode(dct['hr']!);
          SampleCodec.decode(dct['skin_temp_c']!);
          for (final a in _accel) {
            SampleCodec.summary(blobs[a]!);
          }
        });
        out.add('| $day | old DCT archive, full detail | ${dctMs.toStringAsFixed(1)} | ${dct.values.fold<int>(0, (s, b) => s + b.length) + blobs.entries.where((e) => _accel.contains(e.key)).fold<int>(0, (s, e) => s + e.value.length)} B |');

        // 4. Long view: summary pyramid only (what a week/month chart reads).
        final pyrMs = await _medianMs(() async {
          for (final b in blobs.values) {
            SampleCodec.summary(b);
          }
        });
        out.add('| $day | archive, summary levels only (long views) | ${pyrMs.toStringAsFixed(1)} | $archBytes B (header-addressed) |');
      }
    } finally {
      await db.close();
    }
    // ignore: avoid_print
    print(out.join('\n'));
  },
      skip: path == null || path.isEmpty
          ? 'set OPENSTRAP_REAL_DB to run against a real export'
          : false,
      timeout: const Timeout(Duration(minutes: 10)));
}
