// ignore_for_file: file_names
// The @SendableShape round trip for the ECG export page entry (design 02: an
// entry whose argument carries sqlite row maps - Map<String, Object?> - is
// outside the closed grammar and owes a real Isolate.run round trip).
//
// Pins: a page of raw rows (ints, doubles, text, NULLs, BLOBs) and the entry's
// WorkerInputs cross into a worker and the text comes back, byte for byte the
// same as formatting the same rows on this isolate.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_export.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import '../guards/support/sendability.dart';
import 'support/cardio_fixtures.dart';

void main() {
  final rows = [
    cardioReading(id: 'a', maskAny: 2, startOffsetMin: -420).toRow(),
    cardioReading(id: 'b', startTs: kC0 + 60).toRow()..['status'] = 'mystery',
  ];
  final packets = [
    [EcgPacketCodec.toRow(cardioPacket(0)), EcgPacketCodec.toRow(EcgAcceptedPacket.placeholder(1))],
    <Map<String, Object?>>[],
  ];
  final page = EcgRawPage(rows, packets);
  final inputs = WorkerInputs(
    nowEpochMs: kHeader.exportedAt.millisecondsSinceEpoch,
    zoneId: 'UTC',
    localeTag: 'en',
  );

  test('the page crosses an isolate boundary with every cell intact', () async {
    await expectIsolateRoundTrip<EcgRawPage>(
      page,
      project: (p) => [
        for (final r in p.rows) {...r},
        for (final ps in p.packetRows)
          [
            for (final r in ps)
              {
                ...r,
                'samples': (r['samples'] as Uint8List).toList(),
              },
          ],
      ],
    );
  });

  test('the worker answers with the text this isolate would write', () async {
    final inWorker = await Isolate.run(() => ecgFormatPageHeavy(inputs, page));
    final here = [
      for (var i = 0; i < rows.length; i++)
        '\n${formatEcgRow(rows[i], packets[i])}',
    ].join();
    expect(inWorker, here);
  });
}
