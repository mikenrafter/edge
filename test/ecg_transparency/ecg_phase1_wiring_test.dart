// Design 04 phase 1 (RED): the wiring that has no seam to pump (AGENTS 4.7:
// "a capability wired into one call path but not all N"), as source guards and
// one real-store load:
//   * AppState hands the controller the provenance providers (band firmware,
//     app version, UTC offset), and still saves through saveEcgResult;
//   * the screens export through the real path: logFileName + saveLogFileResult
//     (default), ecgLogChunksAll / buildEcgLogFor, LocalDbEcgSource;
//   * the home list reads the default (superseded-hiding) list; the detail data
//     loads the whole attempt group;
//   * the Details accordion is not tied to the Nerd stats setting;
//   * the shared ECG outcome is what the controller publishes.


import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/cardio_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final app = codeOf('lib/state/app_state.dart');
  final ecg = codeOf('lib/ui2/screens/ecg.dart');
  final controller = codeOf('lib/ecg/ecg_controller.dart');

  group('AppState', () {
    final build = app.substring(app.indexOf('EcgController _buildEcg()'));
    final fn = build.substring(0, build.indexOf('c.onFrame'));

    test('still saves through the attempt-grouping store', () {
      expect(fn.contains('LocalDb.saveEcgResult('), isTrue);
      expect(fn.contains('LocalDb.insertEcgReading('), isFalse);
    });

    test('hands the controller the three provenance providers', () {
      expect(fn.contains('firmwareVersion:'), isTrue);
      expect(fn.contains('engine.bandFirmware'), isTrue);
      expect(fn.contains('appVersion:'), isTrue);
      expect(fn.contains('_appVersionLabel'), isTrue);
      expect(fn.contains('utcOffsetMin:'), isTrue);
    });

    test('an app version that has not loaded yet is "not recorded", not an '
        'empty string stored as a version', () {
      // _appVersionLabel is '' until PackageInfo answers.
      expect(RegExp(r"_appVersionLabel\.isEmpty\s*\?\s*null").hasMatch(fn), isTrue);
    });
  });

  group('the controller', () {
    test('publishes the shared outcome of what it saved', () {
      expect(controller.contains('ecgOutcome('), isTrue);
      expect(controller.contains('outcome:'), isTrue);
    });

    test('stamps the table version from the one constant', () {
      expect(controller.contains('kEcgOutcomeTableVersion'), isTrue);
    });
  });

  group('the screens', () {
    test('export through logFileName + saveLogChunksResult, by default', () {
      expect(ecg.contains('saveLogChunksResult'), isTrue);
      expect(ecg.contains('logFileName('), isTrue);
      expect(ecg.contains('ecgLogChunksAll('), isTrue);
      expect(ecg.contains('buildEcgLogFor('), isTrue);
      expect(ecg.contains('LocalDbEcgSource'), isTrue);
    });

    test('the pins and versions in an export come from their constants', () {
      expect(ecg.contains('kAnalyticsPin'), isTrue);
      expect(ecg.contains('kProtocolPin'), isTrue);
      expect(ecg.contains('kAlgoVersion'), isTrue);
      expect(ecg.contains('kEcgOutcomeTableVersion'), isTrue);
    });

    test('the home list is the default list (superseded rows hidden)', () {
      expect(ecg.contains('includeSuperseded: true'), isFalse);
      expect(ecg.contains('listEcgReadings('), isTrue);
    });

    test('the detail loads its whole attempt group', () {
      expect(ecg.contains('ecgAttempts('), isTrue);
    });

    test('the Details accordion is not tied to the Nerd stats setting', () {
      expect(ecg.toLowerCase().contains('nerd'), isFalse);
      expect(ecg.contains("ValueKey('ecg-details')"), isTrue);
    });

    test('deleting goes through the one group delete', () {
      expect(ecg.contains('deleteEcgReading('), isTrue);
    });
  });

  group('EcgDetailData.load (real LocalDb)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_ecg_phase1_wiring_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('a reading in a three-attempt group loads all three, in attempt '
        'order, and its own kept packets', () async {
      await LocalDb.saveEcgResult(unreadableEndingAt(kC0 + 1000, id: 'A').toRow(), [cardioPacketRow(0)]);
      await LocalDb.saveEcgResult(inconclusiveAt(kC0 + 1000 + 150, id: 'B').toRow(), const []);
      await LocalDb.saveEcgResult(
        cardioReading(id: 'C', startTs: kC0 + 1000 + 150 + 60).toRow(),
        [cardioPacketRow(0), cardioPacketRow(1)],
      );
      for (final from in ['A', 'C']) {
        final d = (await EcgDetailData.load(from))!;
        expect([for (final r in d.attempts) r.id], ['A', 'B', 'C'], reason: from);
        expect([for (final r in d.attempts) r.attempt], [1, 2, 3]);
        expect(d.reading.id, from);
      }
      expect((await EcgDetailData.load('C'))!.packets, hasLength(2));
      expect((await EcgDetailData.load('A'))!.packets, hasLength(1));
    });

    test('a reading with no earlier attempt loads as a group of one', () async {
      await LocalDb.saveEcgResult(cardioReading(id: 'solo', startTs: kC0 + 90000).toRow(), const []);
      final d = (await EcgDetailData.load('solo'))!;
      expect(d.attempts.length, lessThanOrEqualTo(1));
      expect([for (final r in d.attempts) r.id].every((i) => i == 'solo'), isTrue);
    });
  });
}
