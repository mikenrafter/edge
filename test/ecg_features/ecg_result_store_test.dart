// ECG features, phase 1 (RED): saving a finished result through
// LocalDb.saveEcgResult. Real LocalDb over sqflite_common_ffi.
//
// Pinned: every field of a result is stored and reads back; a metric that is
// absent stays NULL (never 0); no waveform packet rows unless the caller hands
// packets (the controller only does when the wearer keeps the waveform, see
// ecg_controller_features_test.dart) and nothing here touches the raw R16
// ledger; the attempt-join rule is applied INSIDE the transaction against the
// most recent reading by end time (and deletes nothing); and a failed save
// leaves the earlier attempt exactly as it was.
//
// Waveform policy (decision): a reading is user-initiated, but "Take ECG" asks
// for a result, not for a saved recording. By default only the derived metrics
// and the quality are stored (sample count, min, max and RMS amplitude stay as
// derived facts); the accepted waveform is stored only when the wearer chose
// "Keep waveform", the same explicit-action rule as the Device lab IMU "Save
// recording" (AGENTS.md invariant 14). Raw live 0x2B frames are never stored.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ecg_fixtures.dart';

Future<String?> _save(EcgReading r, {int packets = 0}) => LocalDb.saveEcgResult(
  r.toRow(),
  [for (var i = 0; i < packets; i++) packetRow(i)],
);

Future<List<String>> _ids() async => [
  for (final r in await LocalDb.listEcgReadings()) r['id']! as String,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_ecg_result_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('ecg_reading_packet');
    await db.delete('ecg_reading');
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('the fields', () {
    test('a complete result: start, end, duration, state, metrics and quality '
        'all read back', () async {
      final r = fixtureReading(
        id: 'full',
        avgHr: 64,
        quality: 3,
        interruptions: 1,
        sampleCount: 3000,
      );
      expect(await _save(r), isNull, reason: 'nothing to supersede');
      final back = EcgReading.fromRow((await LocalDb.ecgReading('full'))!)!;
      expect(back.startTs, r.startTs);
      expect(back.endTs, r.endTs);
      expect(back.durationS, 30);
      expect(back.status, EcgReadingStatus.completed);
      expect(back.category, EcgCategory.sinusRhythm);
      expect(back.avgHr, 64);
      expect(back.quality, 3);
      expect(back.interruptions, 1);
      expect(back.sampleCount, 3000);
      expect(back.stopReason, isNull);
    });

    test('a partial result keeps its state and why it stopped, carries no '
        'band verdict, and its absent metrics stay NULL (not 0)', () async {
      await _save(partialEndingAt(kT0 + 12, id: 'part'));
      final row = (await LocalDb.ecgReading('part'))!;
      expect(row['status'], 'partial');
      expect(row['stop_reason'], 'paused');
      expect(row['result_code'], 0, reason: 'the band never gave a result');
      expect(row['category'], 'inconclusive');
      expect(row['avg_hr'], isNull);
      expect(row['quality'], isNull);
      final back = EcgReading.fromRow(row)!;
      expect(back.status, EcgReadingStatus.partial);
      expect(back.stopReason, 'paused');
      expect(back.avgHr, isNull);
      expect(back.quality, isNull);
    });

    test('a partial with enough signal stores its metrics', () async {
      await _save(fixtureReading(
        id: 'part_ok',
        status: EcgReadingStatus.partial,
        category: EcgCategory.inconclusive,
        resultCode: 0,
        avgHr: 70,
        quality: 2,
        sampleCount: 1500,
        stopReason: 'timeout',
      ));
      final back = EcgReading.fromRow((await LocalDb.ecgReading('part_ok'))!)!;
      expect(back.avgHr, 70);
      expect(back.quality, 2);
      expect(back.stopReason, 'timeout');
    });

    test('a legacy-shaped completed row (no stop_reason) still reads', () async {
      await LocalDb.insertEcgReading(
        (fixtureReading(id: 'legacy').toRow())..remove('stop_reason'),
        const [],
      );
      final back = EcgReading.fromRow((await LocalDb.ecgReading('legacy'))!)!;
      expect(back.status, EcgReadingStatus.completed);
      expect(back.stopReason, isNull);
    });
  });

  group('the waveform and the raw ledger', () {
    test('handed no packets, stores none: only derived metrics, quality and '
        'the sample statistics', () async {
      await _save(fixtureReading(id: 'nowave'));
      expect(await LocalDb.ecgReadingPackets('nowave'), isEmpty);
      final row = (await LocalDb.ecgReading('nowave'))!;
      expect(row['sample_count'], 3000);
      expect(row['rms_uv'], isNotNull);
    });

    test('handed packets (the wearer kept the waveform), stores exactly '
        'them, in order', () async {
      await _save(fixtureReading(id: 'wave'), packets: 3);
      final rows = await LocalDb.ecgReadingPackets('wave');
      expect(rows.map((r) => r['ordinal']), [0, 1, 2]);
      expect(rows.map((r) => r['sequence']), [0, 1, 2]);
    });

    test('saving a result never writes the raw R16 ledger', () async {
      final before = await LocalDb.ecgRawPacketCount();
      await _save(fixtureReading(id: 'raw1'), packets: 2);
      await _save(inconclusiveEndingAt(kT0 + 5000, id: 'raw2'));
      expect(await LocalDb.ecgRawPacketCount(), before);
      final db = await LocalDb.instance;
      final linked = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM ecg_raw_packet WHERE reading_id IN (?, ?)',
        ['raw1', 'raw2'],
      );
      expect(linked.single['n'], 0);
    });
  });

  // Design 04: a retake no longer deletes the inconclusive reading. It joins
  // its attempt group; the earlier attempt keeps its row and packets, marked
  // superseded and hidden from the default list. (The full matrix is in
  // test/ecg_transparency/ecg_attempts_store_test.dart.)
  group('joining an inconclusive reading', () {
    Future<List<String>> all() async => [
      for (final r in await LocalDb.listEcgReadings(includeSuperseded: true))
        r['id']! as String,
    ];

    test('a reading that starts 5 minutes after an inconclusive one joins it: '
        'the old row AND its packets are KEPT, superseded, in one save',
        () async {
      final a = inconclusiveEndingAt(kT0 + 1000, id: 'A');
      await _save(a, packets: 2);
      final b = fixtureReading(id: 'B', startTs: kT0 + 1000 + 300);
      expect(await _save(b, packets: 1), 'A', reason: 'the id it superseded');
      expect(await _ids(), ['B'], reason: 'the default list hides A');
      expect(await all(), unorderedEquals(['A', 'B']));
      expect(await LocalDb.ecgReadingPackets('A'), hasLength(2));
      expect(await LocalDb.ecgReadingPackets('B'), hasLength(1));
      expect((await LocalDb.ecgReading('A'))!['superseded_by'], 'B');
    });

    test('an inconclusive reading joins an inconclusive one', () async {
      await _save(inconclusiveEndingAt(kT0 + 1000, id: 'A'));
      final b = inconclusiveEndingAt(kT0 + 1000 + 200 + 30, id: 'B');
      expect(await _save(b), 'A');
      expect(await _ids(), ['B']);
      expect(await all(), unorderedEquals(['A', 'B']));
    });

    test('after a complete reading the next one is added; the complete one '
        'is never touched', () async {
      await _save(fixtureReading(id: 'A', endTs: kT0 + 1000), packets: 2);
      expect(await _save(fixtureReading(id: 'B', startTs: kT0 + 1100)), isNull);
      expect(await _ids(), unorderedEquals(['A', 'B']));
      expect(await LocalDb.ecgReadingPackets('A'), hasLength(2));
    });

    test('more than 10 minutes later is a new group, the inconclusive one '
        'stays current', () async {
      await _save(inconclusiveEndingAt(kT0 + 1000, id: 'A'));
      expect(await _save(fixtureReading(id: 'B', startTs: kT0 + 1000 + 601)),
          isNull);
      expect(await _ids(), unorderedEquals(['A', 'B']));
    });

    test('exactly 10 minutes later still joins', () async {
      await _save(inconclusiveEndingAt(kT0 + 1000, id: 'A'));
      expect(await _save(fixtureReading(id: 'B', startTs: kT0 + 1600)), 'A');
      expect(await _ids(), ['B']);
    });

    test('a partial result is added beside the inconclusive one, not as a '
        'further attempt', () async {
      await _save(inconclusiveEndingAt(kT0 + 1000, id: 'A'));
      expect(await _save(partialEndingAt(kT0 + 1100 + 12, id: 'P')), isNull);
      expect(await _ids(), unorderedEquals(['A', 'P']));
    });

    test('only the MOST RECENT reading (by end time) can be joined: an older '
        'inconclusive one behind a newer complete one stays current',
        () async {
      await _save(inconclusiveEndingAt(kT0 + 1000, id: 'A'));
      await _save(fixtureReading(id: 'C', startTs: kT0 + 4000)); // 10+ min later
      // D starts 3 min after A ended but A is not the latest reading.
      expect(await _save(fixtureReading(id: 'D', startTs: kT0 + 4040)), isNull);
      expect(await _ids(), unorderedEquals(['A', 'C', 'D']));
    });

    test('a failed save rolls back: the old inconclusive reading and its '
        'packets are exactly as they were (not superseded), the new one is '
        'absent', () async {
      await _save(inconclusiveEndingAt(kT0 + 1000, id: 'A'), packets: 2);
      final bad = fixtureReading(id: 'B', startTs: kT0 + 1100);
      await expectLater(
        () => LocalDb.saveEcgResult(bad.toRow(), [
          packetRow(0),
          packetRow(1)..remove('sample_count'), // NOT NULL violation
        ]),
        throwsA(isA<DatabaseException>()),
      );
      expect(await _ids(), ['A']);
      expect(await LocalDb.ecgReadingPackets('A'), hasLength(2));
      expect(await LocalDb.ecgReadingPackets('B'), isEmpty);
      expect((await LocalDb.ecgReading('A'))!['superseded_by'], isNull);
    });

    test('re-saving the same reading id is refused, not merged', () async {
      await _save(fixtureReading(id: 'A'));
      await expectLater(
        () => _save(fixtureReading(id: 'A')),
        throwsA(isA<DatabaseException>()),
      );
      expect(await _ids(), ['A']);
    });
  });
}
