// Design 04 phase 1 (RED) - item 2, the pure half: the attempt-group join rule
// (R2''') and the reading's new provenance fields as typed row data (R3).
//
// JOIN RULE (R2'''): an incoming reading JOINS the latest reading's group iff
//   gap = incoming.start_ts - latest.end_ts, 0 <= gap <= 600 s, AND
//   the latest is non-final (status inconclusive, OR category unreadable -
//   status stays `completed` for unreadable), AND neither is a partial.
// Boundary tests at gap -1, 0, 600, 601. A negative gap (overlap / clock skew)
// starts a new group.
//
// ASSUMED API: ecgJoinTargetId({latest, incoming}) -> id of the reading joined
// or null (lib/ecg/ecg_result.dart); EcgReading gains maskAny, supersededBy,
// attemptGroup, attempt, liveHr, variabilityRaw, firmwareVersion,
// captureAppVersion, captureTableVersion, startOffsetMin, all mapped by
// toRow/fromRow to the schema-70 columns (mask_any, superseded_by,
// attempt_group, attempt, live_hr, variability_raw, firmware_version,
// capture_app_version, capture_table_version, start_offset_min).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_result.dart';

import 'support/cardio_fixtures.dart';

String? _join(EcgReading? latest, EcgReading incoming) =>
    ecgJoinTargetId(latest: latest, incoming: incoming);

void main() {
  const end = kC0 + 1000;

  group('the join boundary (non-final latest)', () {
    for (final (name, make) in <(String, EcgReading Function())>[
      ('an inconclusive reading', () => inconclusiveAt(end, id: 'L')),
      ('an unreadable reading (status completed)', () => unreadableEndingAt(end, id: 'L')),
    ]) {
      group(name, () {
        EcgReading incomingAt(int gap) =>
            cardioReading(id: 'N', startTs: end + gap);
        test('gap -1 (overlap / skew) starts a new group', () {
          expect(_join(make(), incomingAt(-1)), isNull);
        });
        test('gap 0 joins', () => expect(_join(make(), incomingAt(0)), 'L'));
        test('gap 1 joins', () => expect(_join(make(), incomingAt(1)), 'L'));
        test('gap 600 joins (the 10-minute window is inclusive)', () {
          expect(_join(make(), incomingAt(600)), 'L');
        });
        test('gap 601 starts a new group', () {
          expect(_join(make(), incomingAt(601)), isNull);
        });
      });
    }
  });

  group('what is final', () {
    test('a completed reading with a rhythm category is final: never joined, '
        'even at gap 0', () {
      final latest = cardioReading(id: 'L', endTs: end);
      expect(_join(latest, cardioReading(id: 'N', startTs: end)), isNull);
    });

    test('a completed high-heart-rate reading is final too', () {
      final latest = cardioReading(
        id: 'L',
        endTs: end,
        category: EcgCategory.highHeartRate,
        resultCode: 4,
        avgHr: 170,
      );
      expect(_join(latest, cardioReading(id: 'N', startTs: end + 5)), isNull);
    });

    test('a partial latest is never joined', () {
      expect(_join(partialAt(end, id: 'L'), cardioReading(id: 'N', startTs: end + 5)),
          isNull);
    });

    test('a partial INCOMING never joins, even after an inconclusive in the '
        'window', () {
      expect(_join(inconclusiveAt(end, id: 'L'), partialAt(end + 60 + 12, id: 'N')),
          isNull);
    });

    test('no latest reading: a new group', () {
      expect(_join(null, cardioReading(id: 'N')), isNull);
    });

    test('an inconclusive incoming joins an unreadable latest', () {
      expect(_join(unreadableEndingAt(end, id: 'L'),
              inconclusiveAt(end + 90 + 30, id: 'N')),
          'L');
    });
  });

  group('the new fields as row data', () {
    test('every phase-1 column round-trips through toRow / fromRow', () {
      final r = cardioReading(
        id: 'rt',
        maskAny: 6,
        supersededBy: 'next',
        attemptGroup: 'grp',
        attempt: 2,
        liveHr: 78,
        variabilityRaw: 1234,
        firmwareVersion: '5.2.1',
        captureAppVersion: '0.9.30+88',
        captureTableVersion: 2,
        startOffsetMin: -420,
      );
      final row = r.toRow();
      expect(row['mask_any'], 6);
      expect(row['superseded_by'], 'next');
      expect(row['attempt_group'], 'grp');
      expect(row['attempt'], 2);
      expect(row['live_hr'], 78);
      expect(row['variability_raw'], 1234);
      expect(row['firmware_version'], '5.2.1');
      expect(row['capture_app_version'], '0.9.30+88');
      expect(row['capture_table_version'], 2);
      expect(row['start_offset_min'], -420);
      final back = EcgReading.fromRow(row)!;
      expect(back.maskAny, 6);
      expect(back.supersededBy, 'next');
      expect(back.attemptGroup, 'grp');
      expect(back.attempt, 2);
      expect(back.liveHr, 78);
      expect(back.variabilityRaw, 1234);
      expect(back.firmwareVersion, '5.2.1');
      expect(back.captureAppVersion, '0.9.30+88');
      expect(back.captureTableVersion, 2);
      expect(back.startOffsetMin, -420);
    });

    test('NULL stays NULL: a legacy-shaped row has no invented value (sentinel '
        'stays absent, zero stays zero)', () {
      final row = cardioReading(id: 'legacy').toRow();
      for (final k in [
        'mask_any', 'superseded_by', 'attempt_group', 'attempt', 'live_hr',
        'variability_raw', 'firmware_version', 'capture_app_version',
        'capture_table_version', 'start_offset_min',
      ]) {
        expect(row.containsKey(k), isTrue, reason: '$k is a column of the row');
        expect(row[k], isNull, reason: k);
      }
      final legacy = <String, Object?>{...row}
        ..removeWhere((k, _) => const {
          'mask_any', 'superseded_by', 'attempt_group', 'attempt', 'live_hr',
          'variability_raw', 'firmware_version', 'capture_app_version',
          'capture_table_version', 'start_offset_min',
        }.contains(k));
      final back = EcgReading.fromRow(legacy)!;
      expect(back.maskAny, isNull);
      expect(back.liveHr, isNull);
      expect(back.variabilityRaw, isNull);
      expect(back.captureTableVersion, isNull);
      expect(back.startOffsetMin, isNull);
    });

    test('a stored 0 is a measured 0, not "none"', () {
      final back = EcgReading.fromRow(
        cardioReading(maskAny: 0, startOffsetMin: 0, variabilityRaw: 0).toRow(),
      )!;
      expect(back.maskAny, 0);
      expect(back.startOffsetMin, 0);
      expect(back.variabilityRaw, 0);
    });
  });
}
