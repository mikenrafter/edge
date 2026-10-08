// Design 04 phase 1 (RED) - items 2 and 5 on the HOME screen, over a real
// LocalDb (sqflite_common_ffi): the default history hides superseded attempts,
// and "Export ECG logs" saves ONE file through the injected LogResultSaver with
// every reading (superseded included), oldest -> newest; a failure shows
// "Couldn't save the ECG log: <reason>"; nothing touches the clipboard.
//
// ASSUMED keys: `ecg-export-all`; button text "Export ECG logs".

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion, kAnalyticsPin, kProtocolPin;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_export.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/util/log_file.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/cardio_fixtures.dart';
import 'support/ecg_home_harness.dart';

final _now = DateTime.utc(2026, 10, 8, 12, 0, 0);
final _env = EcgExportEnv(appVersion: () async => '9.9.9+99', now: () => _now);

String _stamp() =>
    logFileName('k', _now).split('-log-').last.replaceAll('.txt', '');

String _allText(WidgetTester t) =>
    t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');

EcgReading _chain(String id, int attempt) => cardioReading(
  id: id,
  startTs: kC0 + attempt * 200,
  attemptGroup: 'A',
  attempt: attempt,
  supersededBy: attempt < 3 ? ['B', 'C'][attempt - 1] : null,
);

/// A -> B -> C attempt chain straight into the table (the store's own save is
/// covered in ecg_attempts_store_test.dart). Run inside t.runAsync: sqflite
/// needs real time.
Future<void> _seed() async {
  final db = await LocalDb.instance;
  await db.delete('ecg_reading_packet');
  await db.delete('ecg_reading');
  for (final r in [_chain('A', 1), _chain('B', 2), _chain('C', 3)]) {
    await db.insert('ecg_reading', r.toRow());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboard = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_ecg_home_ui_test.db';
  });
  setUp(() async {
    clipboard.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('Clipboard.')) clipboard.add(call.method);
      return null;
    });
    await resetPrefs();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('the history list (real LocalDb)', () {
    testWidgets('superseded attempts are not listed; the latest is',
        (t) async {
      await t.runAsync(_seed);
      await pumpWithApp(t, const EcgHomeScreen(), ready: find.byType(EcgReadingRow));
      expect(find.byType(EcgReadingRow), findsOneWidget);
      final shown = t.widget<EcgReadingRow>(find.byType(EcgReadingRow)).reading;
      expect(shown.id, 'C');
    });
  });

  group('Export ECG logs (home)', () {
    testWidgets('the button is there; tapping saves ONE file named from the '
        'injected clock, holding every reading INCLUDING superseded ones',
        (t) async {
      await t.runAsync(_seed);
      final saved = <(String, String)>[];
      await pumpWithApp(
        t,
        EcgHomeScreen(
          exportEnv: _env,
          saveLog: (name, chunks) async {
            saved.add((name, await chunks.join()));
            return const LogSaveOk();
          },
        ),
        ready: find.byType(EcgReadingRow),
      );
      expect(find.text('Export ECG logs'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ecg-export-all')));
      for (var i = 0; i < 20 && saved.isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(saved, hasLength(1));
      final (name, text) = saved.single;
      expect(name, matches(RegExp('^openstrap-ecg[a-z-]*-log-${_stamp()}\\.txt\$')));
      expect(RegExp(r'^id: ', multiLine: true).allMatches(text).length, 3,
          reason: 'A, B, C - superseded rows are exported');
      expect(text.indexOf('id: A'), lessThan(text.indexOf('id: B')));
      expect(text.indexOf('id: B'), lessThan(text.indexOf('id: C')));
      expect(text, contains(kAnalyticsPin));
      expect(text, contains(kProtocolPin));
      expect(text, contains('$kAlgoVersion'));
      expect(text, contains('9.9.9+99'));
      expect(text, isNot(contains("Couldn't save")));
      expect(clipboard, isEmpty, reason: 'invariant 16: never the clipboard');
    });

    testWidgets('a save that fails shows "Couldn\'t save the ECG log: <reason>" '
        'and nothing reads as saved', (t) async {
      await t.runAsync(_seed);
      await pumpWithApp(
        t,
        EcgHomeScreen(
          exportEnv: _env,
          saveLog: (name, chunks) async => const LogSaveFailed('disk full'),
        ),
        ready: find.byType(EcgReadingRow),
      );
      await t.tap(find.byKey(const ValueKey('ecg-export-all')));
      for (var i = 0; i < 20; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(find.text("Couldn't save the ECG log: disk full"), findsOneWidget);
      expect(_allText(t).toLowerCase(), isNot(contains('log saved')));
      expect(clipboard, isEmpty);
    });
  });
}
