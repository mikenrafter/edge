// Design 04 phase 1 (RED) - item 5: the ECG log export format (R7' / R7'').
//
// ASSUMED FORMAT (lib/ecg/ecg_export.dart), UTF-8 text of `key: value` lines:
//   header block, keys in this order: app_version, analytics_pin,
//     protocol_pin, algo_version, outcome_table_version, exported_at (UTC ISO
//     from the injected header, never DateTime.now()).
//   then readings oldest -> newest by start_ts then id; each a block that BEGINS
//   at its `id: ` line, with EXACTLY these keys in this order (R7'):
//     id, attempt_group, attempt, superseded_by, start, end, start_offset_min,
//     outcome_kind, reasons, caveats, result_code, category, avg_hr, live_hr,
//     quality, unreadable_mask, mask_any, variability_raw, min_uv, max_uv,
//     rms_uv, sample_count, missing_segments, interruptions, stop_reason,
//     firmware_version, capture_app_version, capture_table_version
//   an absent value prints `not recorded` (superseded_by of a current reading
//   may print `none` instead - see the report); `reasons` / `caveats` print
//   their ids comma-separated (EcgReason.toString(), EcgCaveat.name) or `none`;
//   start / end are UTC ISO-8601 ending in Z.
//   then `packets: not kept` (the literal line) or `packets: N` followed by N
//   lines `packet: ordinal=O sequence=S strap_seconds=T strap_subsec=U
//   sample_count=C inner_hex=HEX samples=CSV` (a placeholder second prints
//   `not recorded` for the strap time and carries `placeholder=1` before
//   inner_hex... see below).

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_export.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

import 'support/cardio_fixtures.dart';

const _keys = [
  'id', 'attempt_group', 'attempt', 'superseded_by', 'start', 'end',
  'start_offset_min', 'outcome_kind', 'reasons', 'caveats', 'result_code',
  'category', 'avg_hr', 'live_hr', 'quality', 'unreadable_mask', 'mask_any',
  'variability_raw', 'min_uv', 'max_uv', 'rms_uv', 'sample_count',
  'missing_segments', 'interruptions', 'stop_reason', 'firmware_version',
  'capture_app_version', 'capture_table_version',
];

/// The reading blocks of [text]: each from its `id: ` line to the next.
List<List<String>> _blocks(String text) {
  final lines = text.split('\n');
  final starts = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].startsWith('id: ')) i,
  ];
  return [
    for (var b = 0; b < starts.length; b++)
      lines.sublist(starts[b], b + 1 < starts.length ? starts[b + 1] : lines.length),
  ];
}

/// `key: value` of every line in a block that has the shape.
Map<String, String> _kv(List<String> block) {
  final m = <String, String>{};
  for (final l in block) {
    final i = l.indexOf(': ');
    if (i > 0 && !l.startsWith('packet:')) m.putIfAbsent(l.substring(0, i), () => l.substring(i + 2));
  }
  return m;
}

List<String> _orderedKeys(List<String> block) => [
  for (final l in block)
    if (RegExp(r'^[a-z_]+: ').hasMatch(l) && !l.startsWith('packet')) l.substring(0, l.indexOf(': ')),
].takeWhile((k) => k != 'packets').toList();

String _iso(int epochS) => DateTime.fromMillisecondsSinceEpoch(
  epochS * 1000,
  isUtc: true,
).toIso8601String().substring(0, 19);

EcgReading get _full => cardioReading(
  id: 'full',
  attemptGroup: 'g1',
  attempt: 2,
  supersededBy: 'next',
  unreadableMask: 2,
  maskAny: 6,
  liveHr: 78,
  variabilityRaw: 1234,
  interruptions: 1,
  firmwareVersion: '5.2.1',
  captureAppVersion: '0.9.30+88',
  captureTableVersion: 2,
  startOffsetMin: -420,
);

void main() {
  group('the header block', () {
    test('has the app version, both pins, kAlgoVersion, the table version and '
        'the injected export time, in that order', () {
      final lines = formatEcgHeader(kHeader).split('\n');
      final order = [
        'app_version: 9.9.9+99',
        'analytics_pin: ${'a' * 40}',
        'protocol_pin: ${'b' * 40}',
        'algo_version: 102',
        'outcome_table_version: ${kHeader.outcomeTableVersion}',
      ];
      var at = -1;
      for (final want in order) {
        final i = lines.indexOf(want);
        expect(i, greaterThan(at), reason: want);
        at = i;
      }
      final exported = lines.firstWhere((l) => l.startsWith('exported_at: '));
      expect(exported, startsWith('exported_at: 2026-10-08T12:00:00'));
      expect(lines.indexOf(exported), greaterThan(at));
    });

    test('the export time is the one handed in, not the wall clock', () {
      final a = formatEcgHeader(kHeader);
      final b = formatEcgHeader(EcgExportHeader(
        appVersion: kHeader.appVersion,
        analyticsPin: kHeader.analyticsPin,
        protocolPin: kHeader.protocolPin,
        algoVersion: kHeader.algoVersion,
        outcomeTableVersion: kHeader.outcomeTableVersion,
        exportedAt: DateTime.utc(2027, 1, 2, 3, 4, 5),
      ));
      expect(a, formatEcgHeader(kHeader), reason: 'deterministic');
      expect(a, isNot(b));
      expect(b, contains('exported_at: 2027-01-02T03:04:05'));
    });
  });

  group('a reading block', () {
    test('the keys are exactly the R7\' list, in the R7\' order', () {
      final block = _blocks(formatEcgReading(_full, const [])).single;
      expect(_orderedKeys(block), _keys);
    });

    test('a fully recorded reading prints every value', () {
      final kv = _kv(_blocks(formatEcgReading(_full, const [])).single);
      expect(kv['id'], 'full');
      expect(kv['attempt_group'], 'g1');
      expect(kv['attempt'], '2');
      expect(kv['superseded_by'], 'next');
      expect(kv['start'], startsWith(_iso(_full.startTs)));
      expect(kv['start'], endsWith('Z'));
      expect(kv['end'], startsWith(_iso(_full.endTs)));
      expect(kv['start_offset_min'], '-420');
      expect(kv['outcome_kind'], 'notReadable');
      expect(kv['reasons'], 'significant_noise, unstable_signal');
      expect(kv['caveats'], 'none');
      expect(kv['result_code'], '1');
      expect(kv['category'], 'sinusRhythm');
      expect(kv['avg_hr'], '77');
      expect(kv['live_hr'], '78');
      expect(kv['quality'], '3');
      expect(kv['unreadable_mask'], '2');
      expect(kv['mask_any'], '6');
      expect(kv['variability_raw'], '1234');
      expect(kv['min_uv'], '-500');
      expect(kv['max_uv'], '700');
      expect(kv['rms_uv'], '120.5');
      expect(kv['sample_count'], '3000');
      expect(kv['missing_segments'], '0');
      expect(kv['interruptions'], '1');
      expect(kv['firmware_version'], '5.2.1');
      expect(kv['capture_app_version'], '0.9.30+88');
      expect(kv['capture_table_version'], '2');
    });

    test('a clean band result prints its caveat and no reasons', () {
      final kv = _kv(_blocks(formatEcgReading(cardioReading(maskAny: 0), const [])).single);
      expect(kv['outcome_kind'], 'bandResult');
      expect(kv['reasons'], 'none');
      expect(kv['caveats'], 'bandReportedQualityUnchecked');
    });

    test('a legacy row prints "not recorded" for every NULL, and the stored '
        'raw values as they are', () {
      final kv = _kv(_blocks(formatEcgReading(cardioReading(id: 'old'), const [])).single);
      for (final k in [
        'attempt_group', 'attempt', 'start_offset_min', 'live_hr', 'mask_any',
        'variability_raw', 'stop_reason', 'firmware_version',
        'capture_app_version', 'capture_table_version',
      ]) {
        expect(kv[k], 'not recorded', reason: k);
      }
      expect(kv['superseded_by'], anyOf('not recorded', 'none'));
      expect(kv['result_code'], '1');
      expect(kv['avg_hr'], '77');
    });

    test('a NULL average rate and quality print "not recorded", not 0', () {
      final kv = _kv(_blocks(
        formatEcgReading(cardioReading(avgHr: null, quality: null), const []),
      ).single);
      expect(kv['avg_hr'], 'not recorded');
      expect(kv['quality'], 'not recorded');
    });

    test('a measured zero prints 0, never "not recorded"', () {
      final kv = _kv(_blocks(formatEcgReading(
        cardioReading(maskAny: 0, startOffsetMin: 0, variabilityRaw: 0, liveHr: 0),
        const [],
      )).single);
      for (final k in ['mask_any', 'start_offset_min', 'variability_raw', 'live_hr']) {
        expect(kv[k], '0', reason: k);
      }
    });

    test('a partial row says why it stopped', () {
      final kv = _kv(_blocks(formatEcgReading(partialAt(kC0 + 12), const [])).single);
      expect(kv['outcome_kind'], 'partial');
      expect(kv['stop_reason'], 'paused');
    });
  });

  group('packets', () {
    test('Keep waveform off: the literal line "packets: not kept"', () {
      final text = formatEcgReading(cardioReading(), const []);
      expect(text.split('\n'), contains('packets: not kept'));
      expect(text.contains('packet: '), isFalse);
    });

    test('kept packets: a count, then each packet with its EXACT inner_hex and '
        'its samples as comma-separated microvolts, in ordinal order', () {
      final packets = [for (var i = 0; i < 3; i++) cardioPacket(i)];
      final text = formatEcgReading(cardioReading(), packets);
      final lines = text.split('\n');
      expect(lines, contains('packets: 3'));
      final pl = [for (final l in lines) if (l.startsWith('packet: ')) l];
      expect(pl, hasLength(3));
      final re = RegExp(
        r'^packet: ordinal=(\d+) sequence=(\d+) strap_seconds=(\S+) '
        r'strap_subsec=(\S+) sample_count=(\d+) inner_hex=([0-9a-f]*) '
        r'samples=(\S*)$',
      );
      for (var i = 0; i < 3; i++) {
        final m = re.firstMatch(pl[i]);
        expect(m, isNotNull, reason: pl[i]);
        expect(m![1], '$i');
        expect(m[2], '${packets[i].sequence}');
        expect(m[3], '${packets[i].strapSeconds}');
        expect(m[5], '100');
        expect(m[6], EcgPacketCodec.hex(packets[i].inner),
            reason: 'byte-exact inner hex');
        expect(m[7], packets[i].samples.join(','));
      }
    });

    test('a placeholder second is kept in the count and invents no strap time',
        () {
      final packets = [
        cardioPacket(0),
        EcgAcceptedPacket.placeholder(1),
        cardioPacket(2),
      ];
      final lines = formatEcgReading(cardioReading(), packets).split('\n');
      expect(lines, contains('packets: 3'));
      final ph = lines.where((l) => l.startsWith('packet: ordinal=1 ')).single;
      expect(ph, contains('placeholder'));
      expect(ph, contains('strap_seconds=not recorded'));
      expect(ph, contains('strap_subsec=not recorded'));
    });
  });

  group('one formatter, per reading and in bulk', () {
    test('a reading block is the same text in the bulk log and the per-reading '
        'log', () async {
      final a = cardioReading(id: 'A', attemptGroup: 'A', attempt: 1, supersededBy: 'B');
      final b = cardioReading(id: 'B', startTs: kC0 + 100, attemptGroup: 'A', attempt: 2);
      final src = FakeEcgSource([a, b], packets: {'B': [cardioPacket(1)]});
      final block = formatEcgReading(b, [cardioPacket(1)]);
      final all = await ecgLogChunksAll(header: kHeader, source: src).join();
      final one = await buildEcgLogFor(header: kHeader, source: src, readingId: 'B');
      expect(all, contains(block));
      expect(one, contains(block));
      expect(all, startsWith(formatEcgHeader(kHeader)));
      expect(one, startsWith(formatEcgHeader(kHeader)));
    });

    test('the formatter is the only place a block is built', () {
      for (final f in ['lib/ui2/screens/ecg.dart', 'lib/coach/coach_actions.dart']) {
        final s = File(f).readAsStringSync();
        expect(s.contains('inner_hex='), isFalse, reason: f);
        expect(s.contains('packets: not kept'), isFalse, reason: f);
      }
    });
  });

  group('Export ECG logs: every reading, paged', () {
    List<EcgReading> many(int n) => [
      for (var i = 0; i < n; i++)
        cardioReading(
          // ids deliberately out of order against start_ts; ties every 4th row
          id: 'r${(n - i).toString().padLeft(4, '0')}',
          startTs: kC0 + (i ~/ 4) * 60,
          supersededBy: i % 9 == 0 ? 'x' : null,
        ),
    ];

    test('450 readings (more than the 200 default of listEcgReadings): all of '
        'them, superseded ones too, oldest -> newest by start_ts then id, each '
        'once', () async {
      final all = many(450);
      final src = FakeEcgSource(all);
      final text = await ecgLogChunksAll(header: kHeader, source: src).join();
      final ids = [for (final b in _blocks(text)) _kv(b)['id']!];
      final want = ([...all]..sort((x, y) {
              final c = x.startTs.compareTo(y.startTs);
              return c != 0 ? c : x.id.compareTo(y.id);
            }))
          .map((r) => r.id)
          .toList();
      expect(ids, want);
      expect(ids.toSet().length, 450);
      expect(src.pageCalls.length, greaterThanOrEqualTo(3));
      expect(src.pageCalls.every((c) => c.limit <= 200), isTrue,
          reason: 'paged, never one unbounded read');
      expect(RegExp(r'^app_version: ', multiLine: true).allMatches(text).length, 1,
          reason: 'one header, not one per page');
    });

    test('a small page size changes nothing', () async {
      final all = many(23);
      final a = await ecgLogChunksAll(header: kHeader, source: FakeEcgSource(all)).join();
      final b = await ecgLogChunksAll(header: kHeader, source: FakeEcgSource(all), pageSize: 7).join();
      expect(b, a);
    });

    test('kept packets travel with their reading, and a reading without any '
        'says so', () async {
      final a = cardioReading(id: 'A');
      final b = cardioReading(id: 'B', startTs: kC0 + 100);
      final src = FakeEcgSource([a, b], packets: {'A': [cardioPacket(0), cardioPacket(1)]});
      final blocks = _blocks(await ecgLogChunksAll(header: kHeader, source: src).join());
      expect(blocks[0], contains('packets: 2'));
      expect(blocks[1], contains('packets: not kept'));
    });

    test('an empty store is a header and no readings', () async {
      final text = await ecgLogChunksAll(header: kHeader, source: FakeEcgSource([])).join();
      expect(text, startsWith(formatEcgHeader(kHeader)));
      expect(_blocks(text), isEmpty);
    });
  });

  group('the per-reading log is the attempt group', () {
    test('three attempts: three blocks in attempt order, superseded ones '
        'included, with their chain pointers', () async {
      final a = cardioReading(id: 'A', attemptGroup: 'A', attempt: 1, supersededBy: 'B');
      final b = cardioReading(id: 'B', startTs: kC0 + 100, attemptGroup: 'A', attempt: 2, supersededBy: 'C');
      final c = cardioReading(id: 'C', startTs: kC0 + 200, attemptGroup: 'A', attempt: 3);
      final other = cardioReading(id: 'Z', startTs: kC0 + 9000);
      final text = await buildEcgLogFor(
        header: kHeader,
        source: FakeEcgSource([c, a, other, b]),
        readingId: 'C',
      );
      final blocks = _blocks(text);
      expect([for (final b in blocks) _kv(b)['id']], ['A', 'B', 'C']);
      expect([for (final b in blocks) _kv(b)['attempt']], ['1', '2', '3']);
      expect([for (final b in blocks) _kv(b)['superseded_by']].take(2), ['B', 'C']);
    });

    test('a legacy reading exports as a group of one', () async {
      final text = await buildEcgLogFor(
        header: kHeader,
        source: FakeEcgSource([cardioReading(id: 'old'), cardioReading(id: 'other', startTs: kC0 + 900)]),
        readingId: 'old',
      );
      expect([for (final b in _blocks(text)) _kv(b)['id']], ['old']);
    });
  });


  group('never drop evidence (Sol r1)', () {
    Map<String, Object?> bad(String id, {int startTs = kC0, String status = 'mystery'}) =>
        cardioReading(id: id, startTs: startTs).toRow()..['status'] = status;

    test('a row with an unknown status is exported with its raw columns and '
        'an `outcome: unparseable (reason)` line - not skipped', () async {
      final src = FakeEcgSource(
        [cardioReading(id: 'good', startTs: kC0 + 100)],
        rawRows: [bad('weird')],
      );
      final text = await ecgLogChunksAll(header: kHeader, source: src).join();
      final blocks = _blocks(text);
      expect([for (final b in blocks) _kv(b)['id']], ['weird', 'good']);
      final kv = _kv(blocks.first);
      expect(kv['outcome'], startsWith('unparseable ('));
      expect(kv['outcome'], contains('mystery'));
      expect(kv['status'], 'mystery', reason: 'the raw column, as stored');
      expect(kv['result_code'], '1');
      expect(kv['start_ts'], '$kC0');
      expect(_kv(blocks.last)['outcome_kind'], isNotNull);
    });

    test('an unknown category and an unknown wrist are unparseable too, and '
        'say which', () async {
      final r = cardioReading(id: 'x').toRow()
        ..['category'] = 'sparkles'
        ..['wrist'] = 'ankle';
      final text = await ecgLogChunksAll(
        header: kHeader,
        source: FakeEcgSource(const [], rawRows: [r]),
      ).join();
      final kv = _kv(_blocks(text).single);
      expect(kv['outcome'], contains('sparkles'));
      expect(kv['outcome'], contains('ankle'));
    });

    test('an unparseable row keeps its kept packets', () async {
      final r = bad('weird');
      final text = formatEcgRow(r, [EcgPacketCodec.toRow(cardioPacket(0))]);
      expect(text, contains('packets: 1'));
      expect(text, contains('inner_hex='));
    });

    test('a FULL page of unparseable rows followed by good ones: paging goes '
        'on and every row is exported', () async {
      final badRows = [
        for (var i = 0; i < 6; i++) bad('bad$i', startTs: kC0 + i),
      ];
      final good = [
        for (var i = 0; i < 5; i++) cardioReading(id: 'good$i', startTs: kC0 + 100 + i),
      ];
      final src = FakeEcgSource(good, rawRows: badRows);
      final text = await ecgLogChunksAll(header: kHeader, source: src, pageSize: 3).join();
      final ids = [for (final b in _blocks(text)) _kv(b)['id']];
      expect(ids, [
        for (var i = 0; i < 6; i++) 'bad$i',
        for (var i = 0; i < 5; i++) 'good$i',
      ]);
      expect(src.pageCalls.length, greaterThanOrEqualTo(4));
    });
  });

  group('the bulk log is formatted in a registered worker (Sol r1)', () {
    final fixtures = [
      for (var i = 0; i < 23; i++)
        cardioReading(
          id: 'r${(23 - i).toString().padLeft(3, '0')}',
          startTs: kC0 + (i ~/ 3) * 60,
          attemptGroup: i % 5 == 0 ? 'g$i' : null,
          attempt: i % 5 == 0 ? 1 : null,
          maskAny: i % 4 == 0 ? 2 : null,
        ),
    ];
    final packets = {
      'r010': [cardioPacket(0), EcgAcceptedPacket.placeholder(1), cardioPacket(2)],
    };

    String expectedLikeBefore() {
      final sorted = [...fixtures]..sort((a, b) {
          final c = a.startTs.compareTo(b.startTs);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      final out = StringBuffer(formatEcgHeader(kHeader));
      for (final r in sorted) {
        out
          ..writeln()
          ..write(formatEcgReading(r, packets[r.id] ?? const []));
      }
      return out.toString();
    }

    test('the bytes are exactly what the single-string formatter wrote', () async {
      for (final size in [200, 7, 1]) {
        final text = await ecgLogChunksAll(
          header: kHeader,
          source: FakeEcgSource(fixtures, packets: packets),
          pageSize: size,
        ).join();
        expect(text, expectedLikeBefore(), reason: 'pageSize $size');
      }
    });

    test('it arrives as chunks - the header, then one per page - never one '
        'giant string', () async {
      final chunks = await ecgLogChunksAll(
        header: kHeader,
        source: FakeEcgSource(fixtures, packets: packets),
        pageSize: 7,
      ).toList();
      expect(chunks.first, formatEcgHeader(kHeader));
      expect(chunks.length, 1 + 4, reason: 'header + ceil(23 / 7) pages');
    });

    test('each page is formatted by the registered entry, in a worker '
        'isolate', () async {
      final entries = <EntryEvent>[];
      final dispatches = <DispatchEvent>[];
      WorkerAudit.onEntry = entries.add;
      WorkerAudit.onDispatch = dispatches.add;
      addTearDown(WorkerAudit.reset);
      await ecgLogChunksAll(
        header: kHeader,
        source: FakeEcgSource(fixtures, packets: packets),
        pageSize: 7,
      ).join();
      await pumpEventQueue();
      expect(entries.where((e) => e.entry == 'ecgFormatPageHeavy'), hasLength(4));
      expect(
        entries.every((e) => e.isolateId != WorkerAudit.currentIsolateId),
        isTrue,
        reason: 'formatting ran off the calling isolate',
      );
      expect(dispatches.where((d) => d.kind == Dispatcher.run), hasLength(4));
      expect(
        kWorkerEntries.any((e) => e.symbol == #ecgFormatPageHeavy),
        isTrue,
      );
    });

    test('the per-reading export formats through the same row formatter, on '
        'the calling isolate', () async {
      final entries = <EntryEvent>[];
      WorkerAudit.onEntry = entries.add;
      addTearDown(WorkerAudit.reset);
      final one = await buildEcgLogFor(
        header: kHeader,
        source: FakeEcgSource(fixtures, packets: packets),
        readingId: 'r010',
      );
      expect(one, contains(formatEcgReading(
        fixtures.firstWhere((r) => r.id == 'r010'),
        packets['r010']!,
      )));
      expect(entries, isEmpty, reason: 'bounded: no worker round trip');
    });

    test('an Isolate.run of the entry is deterministic (same page, same text)',
        () async {
      final rows = [for (final r in fixtures.take(5)) r.toRow()];
      final page = EcgRawPage(rows, [for (final _ in rows) const []]);
      final inputs = WorkerInputs(
        nowEpochMs: kHeader.exportedAt.millisecondsSinceEpoch,
        zoneId: 'UTC',
        localeTag: 'en',
      );
      final a = await Isolate.run(() => ecgFormatPageHeavy(inputs, page));
      final b = await Isolate.run(() => ecgFormatPageHeavy(inputs, page));
      expect(a, b);
      expect(a, contains('id: r023'));
    });
  });

  group('source guards', () {
    final src = codeOf('lib/ecg/ecg_export.dart');
    test('the formatter reads no wall clock and no clipboard', () {
      expect(src.contains('DateTime.now('), isFalse);
      expect(src.contains('Clipboard'), isFalse);
    });
    test('it decides the outcome through ecgOutcome', () {
      expect(src.contains('ecgOutcome('), isTrue);
    });
  });
}
