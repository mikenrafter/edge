// DEV-ONLY harness: the sample experiment table on a REAL export.
//
//   OPENSTRAP_REAL_DB=/path/to/openstrap_export.db \
//   OPENSTRAP_REAL_REPORT=/path/to/report.md \
//   TZ=UTC flutter test test/sample/sample_real_data_test.dart
//
// Skipped when OPENSTRAP_REAL_DB is unset (CI, normal runs). The database is
// opened READ-ONLY from wherever it lives: it is never copied into the repo and
// nothing is written next to it. Only AGGREGATE numbers leave this test (bytes,
// ratios, error, segment counts, coverage); no raw sample value is printed or
// written. Bounds are asserted on the real data (the codec's contract); sizes
// are reported, not asserted - this is the measurement the synthetic fixtures
// cannot give.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/sample_codec.dart';

import '../support/sample_fixtures.dart';

const _signals = ['hr', 'ax', 'ay', 'az', 'skin_temp_c'];

void main() {
  final path = Platform.environment['OPENSTRAP_REAL_DB'];
  final reportPath = Platform.environment['OPENSTRAP_REAL_REPORT'];

  test('real export: per device, day and signal', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(path!,
        options: OpenDatabaseOptions(readOnly: true));
    final lines = <String>[];
    var totAd = 0, totSt = 0, totLl = 0, totRaw = 0;
    // Per day: the archive option totals the owner is choosing between.
    final perDay = <String, Map<String, int>>{};
    final quantLines = <String>[];
    try {
      final span = (await db.rawQuery(
              'SELECT MIN(rec_ts) AS a, MAX(rec_ts) AS b, COUNT(*) AS n '
              'FROM decoded_onehz WHERE rec_ts > 0'))
          .first;
      final devices = [
        for (final r in await db.rawQuery(
            'SELECT DISTINCT device_id AS d FROM decoded_onehz ORDER BY 1'))
          (r['d'] as String?) ?? ''
      ];
      lines
        ..add('# Sample archive on a real export (aggregate numbers only)')
        ..add('')
        ..add('- rows: ${span['n']}, devices: ${devices.length}, '
            'TZ=${Platform.environment['TZ'] ?? 'system'}, '
            'codec v${SampleCodec.codecVersion}')
        ..add('- "lossless" = deflate of zigzag first-differences at the '
            "signal's native quantum; \"raw\" = 8 B per valid sample")
        ..add('- adaptive = default mode; static = fixed 240 s blocks; '
            'every-N = keep-every-Nth with linear interpolation at the same '
            'error bounds')
        ..add('')
        ..add('| device | day | signal | valid / slots | raw B | lossless B | '
            'every-N (N) | static B | adaptive B | vs lossless | vs raw | '
            'segs | coeffs | pyramid B | rms | max | enc s | '
            'lossless-at-q B | pyramid-only B |')
        ..add('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
      var day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
          (span['a'] as int) * 1000));
      final last = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
          (span['b'] as int) * 1000));
      while (true) {
        final lo = localDayStartSec(day)!, hi = localDayEndSec(day)!;
        for (final dev in devices) {
          final len = hi - lo;
          final series = {
            for (final s in _signals)
              s: List<double?>.filled(len, null, growable: false)
          };
          const win = 6 * 3600;
          for (var a = lo; a < hi; a += win) {
            final rows = await db.rawQuery(
                'SELECT rec_ts, hr, ax, ay, az, skin_temp_c FROM decoded_onehz '
                'WHERE device_id = ? AND rec_ts >= ? AND rec_ts < ?',
                [dev, a, a + win < hi ? a + win : hi]);
            for (final r in rows) {
              final i = (r['rec_ts'] as int) - lo;
              for (final s in _signals) {
                final v = (r[s] as num?)?.toDouble();
                if (v == null || !v.isFinite || (s == 'hr' && v <= 0)) continue;
                series[s]![i] = v;
              }
            }
          }
          for (final s in _signals) {
            final x = series[s]!;
            final n = validCount(x);
            if (n == 0) continue;
            final spec = SampleCodec.specs[s]!;
            final sw = Stopwatch()..start();
            final ad = SampleCodec.encode(s, x);
            final enc = sw.elapsedMilliseconds / 1000;
            final st = SampleCodec.encode(s, x, mode: SampleMode.staticBlocks);
            for (final e in [ad, st]) {
              final m = errorOf(x, SampleCodec.decode(e.blob));
              expect(m.rms, lessThanOrEqualTo(spec.maxRms), reason: '$day $s');
              expect(m.max, lessThanOrEqualTo(spec.maxAbs), reason: '$day $s');
            }
            final isAccel = s == 'ax' || s == 'ay' || s == 'az';
            SampleEncoding? qz;
            if (spec.step != null) {
              qz = SampleCodec.encode(s, x, mode: SampleMode.quantized);
              final m = errorOf(x, SampleCodec.decode(qz.blob));
              expect(m.max, lessThanOrEqualTo(spec.step! / 2 + 1e-9),
                  reason: '$day $s quantized');
              quantLines.add('| ${dev.isEmpty ? 'primary' : dev} | $day | $s | '
                  '$n | ${qz.stats.bytes} | '
                  '${(losslessBytes(x, spec.quantum) / qz.stats.bytes).toStringAsFixed(2)}x | '
                  '${(n * 8 / qz.stats.bytes).toStringAsFixed(1)}x | '
                  '${qz.stats.summaryBytes} | '
                  '${qz.stats.rmsErr.toStringAsFixed(3)} | '
                  '${qz.stats.maxErr.toStringAsFixed(3)} |');
            }
            var lqB = 0, pyB = 0;
            if (isAccel) {
              final lq = SampleCodec.encode(s, x, mode: SampleMode.losslessAtQuantum);
              final back = SampleCodec.decode(lq.blob);
              for (var i = 0; i < x.length; i++) {
                expect(back[i], x[i] == null ? isNull : (x[i]! / spec.quantum).round() * spec.quantum,
                    reason: '$day $s slot $i lossless');
              }
              final py = SampleCodec.encode(s, x, mode: SampleMode.pyramidOnly);
              lqB = lq.stats.bytes;
              pyB = py.stats.bytes;
            }
            final dm = perDay.putIfAbsent(day, () => {});
            dm['n_$s'] = n;
            if (s == 'hr') dm['hr'] = qz!.stats.bytes;
            if (s == 'skin_temp_c') dm['temp'] = qz!.stats.bytes;
            if (isAccel) {
              dm['accelLossless'] = (dm['accelLossless'] ?? 0) + lqB;
              dm['accelPyramid'] = (dm['accelPyramid'] ?? 0) + pyB;
              dm['accelDct'] = (dm['accelDct'] ?? 0) + ad.stats.bytes;
            }
            final ll = losslessBytes(x, spec.quantum);
            final nth = keepEveryNth(x, spec.quantum, spec.maxRms, spec.maxAbs);
            final raw = n * 8;
            totAd += ad.stats.bytes;
            totSt += st.stats.bytes;
            totLl += ll;
            totRaw += raw;
            lines.add('| ${dev.isEmpty ? 'primary' : dev} | $day | $s | '
                '$n / $len | $raw | $ll | ${nth.bytes} (${nth.n}) | '
                '${st.stats.bytes} | ${ad.stats.bytes} | '
                '${(ll / ad.stats.bytes).toStringAsFixed(2)}x | '
                '${(raw / ad.stats.bytes).toStringAsFixed(1)}x | '
                '${ad.stats.segmentCount} | ${ad.stats.coefficientCount} | '
                '${ad.stats.summaryBytes} | '
                '${ad.stats.rmsErr.toStringAsFixed(3)} | '
                '${ad.stats.maxErr.toStringAsFixed(3)} | '
                '${enc.toStringAsFixed(1)} | '
                '${isAccel ? lqB : '-'} | ${isAccel ? pyB : '-'} |');
          }
        }
        if (day == last) break;
        day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(hi * 1000));
      }
      lines
        ..add('')
        ..add('## Quantized codec (the archive default for hr and skin temp)')
        ..add('')
        ..add('| device | day | signal | valid | bytes | vs lossless | vs raw | '
            'pyramid B | rms | max |')
        ..add('|---|---|---|---|---|---|---|---|---|---|')
        ..addAll(quantLines);
      lines
        ..add('')
        ..add('## Archive options per day (bytes; accel = ax+ay+az)')
        ..add('')
        ..add('| day | hr quantized | temp quantized | accel lossless-at-q | '
            'accel pyramid-only | accel lossy DCT (ref) | TOTAL, lossless accel | '
            'TOTAL, pyramid accel |')
        ..add('|---|---|---|---|---|---|---|---|');
      var sumL = 0, sumP = 0, sumH = 0, sumT = 0, sumAL = 0, sumAP = 0;
      perDay.forEach((d, m) {
        final hr = m['hr'] ?? 0, t = m['temp'] ?? 0;
        final al = m['accelLossless'] ?? 0, ap = m['accelPyramid'] ?? 0;
        sumH += hr;
        sumT += t;
        sumAL += al;
        sumAP += ap;
        sumL += hr + t + al;
        sumP += hr + t + ap;
        lines.add('| $d | $hr | $t | $al | $ap | ${m['accelDct'] ?? 0} | '
            '${hr + t + al} | ${hr + t + ap} |');
      });
      lines.add('| ALL | $sumH | $sumT | $sumAL | $sumAP | - | $sumL | $sumP |');
      lines
        ..add('')
        ..add('Totals over all rows above: raw $totRaw B, lossless $totLl B, '
            'static $totSt B, adaptive $totAd B '
            '(${(totLl / totAd).toStringAsFixed(2)}x vs lossless, '
            '${(totRaw / totAd).toStringAsFixed(1)}x vs raw).');
    } finally {
      await db.close();
    }
    final report = lines.join('\n') + '\n';
    if (reportPath != null && reportPath.isNotEmpty) {
      File(reportPath).writeAsStringSync(report);
    }
    // ignore: avoid_print
    print(report);
  },
      skip: path == null || path.isEmpty
          ? 'set OPENSTRAP_REAL_DB to run on a real export'
          : false,
      timeout: const Timeout(Duration(minutes: 45)));
}
