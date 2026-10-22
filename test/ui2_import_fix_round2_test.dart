// RED: review round 1 of the import page / post-import notes work.
//
//  2. Welcome used to call completeImportOnboard() straight after a good
//     import, so the route moved on and the re-entry warning was never read.
//     It now holds on the result behind a Continue step when there is
//     something to re-enter, and Your data keeps the notes on the app, so
//     leaving the page mid-import does not discard them.
//  3. The notes come WITH the import's result (ImportOutcome.summary,
//     aggregated over a multi-select), not from a global read that can be
//     stale (recordImportSummary keeps the previous row when it fails).
//  4. Copying shows no "rows": the numbers are MAX(rowid) from the data side
//     (import_copy_plan.dart), not a count of rows.
//  6. Consent: restart persistence and the health-share branch.
//
// RED STUBS in lib/: ImportOutcome.summary, AppState.lastBackupSummary /
// importReentry / dismissImportReentry(), AppState.loadConsent(),
// DataScreenView.pendingReentry / onDismissNotes.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as pth;
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/ui2/onboarding/consent_prompt.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/profile/import_progress_view.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import 'support/app_state_derive_harness.dart';

const _keyLine = ValueKey('post-import-reentry-coach_api_key');
const _deviceLine = ValueKey('post-import-device-only');
const _lost = ImportSummary(needsReentry: [kNeedsReentryCoachKey]);

/// Backup imports that report a scripted summary per path; no database.
class _App extends AppState {
  _App(this.summaries) : super.forTesting();
  final Map<String, ImportSummary?> summaries;
  final onboarded = <String>[];
  final telemetryCalls = <bool>[];
  final healthCalls = <bool>[];

  @override
  Future<int> importEdgeBackup(String path) async {
    lastBackupSummary = summaries[pth.basename(path)];
    return 1;
  }

  @override
  Future<void> completeImportOnboard() async => onboarded.add('done');

  @override
  Future<void> setTelemetryConsent(bool on) async {
    telemetryCalls.add(on);
    consentChosen = true;
    notifyListeners();
  }

  @override
  Future<void> setHealthShareConsent(bool on) async {
    healthCalls.add(on);
    consentChosen = true;
    notifyListeners();
  }
}

class _Picker extends FilePicker with MockPlatformInterfaceMixin {
  _Picker(this.paths);
  final List<String> paths;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([
        for (final x in paths) PlatformFile(name: pth.basename(x), size: 0, path: x)
      ]);
}

Widget _app(Widget home, {AppState? app, Capabilities? caps}) {
  Widget h = MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
  if (caps != null) h = Provider<Capabilities>.value(value: caps, child: h);
  if (app != null) {
    h = ChangeNotifierProvider<AppState>.value(value: app, child: h);
  }
  return h;
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 6000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<List<String>> _backups(Directory dir, List<String> names) async => [
      for (final n in names)
        (File('${dir.path}/$n')..writeAsBytesSync([1, 2, 3, 4])).path
    ];

void main() {
  group('3: the summary belongs to the import that produced it', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('import_round2_');
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a multi-select keeps a warning from an EARLIER backup', () async {
      final app = _App({'a.db': _lost, 'b.db': const ImportSummary()});
      addTearDown(app.importProgress.dispose);
      final out = await runImport(app, await _backups(tmp, ['a.db', 'b.db']));
      expect(out.summary, isNotNull);
      expect(out.summary!.needsReentry, [kNeedsReentryCoachKey]);
    });

    test('no warning when no backup lost anything', () async {
      final app = _App({'a.db': const ImportSummary()});
      addTearDown(app.importProgress.dispose);
      final out = await runImport(app, await _backups(tmp, ['a.db']));
      expect(out.summary, isNotNull, reason: 'a backup ran: its answer is known');
      expect(out.summary!.needsReentry, isEmpty);
    });

    test('a backup whose summary could not be recorded claims nothing', () async {
      final app = _App({'a.db': null});
      addTearDown(app.importProgress.dispose);
      final out = await runImport(app, await _backups(tmp, ['a.db']));
      expect(out.summary?.needsReentry ?? const [], isEmpty);
      expect(app.importReentry.value, isEmpty);
    });

    group('recordImportSummary', () {
      const name = 'import_round2_summary.db';
      setUp(() async {
        await deriveDbSetUp(name);
        SharedPreferences.setMockInitialValues({});
      });
      tearDown(() => deriveDbTearDown(name));

      test('a failed record drops the previous summary instead of keeping it',
          () async {
        await recordImportSummary('${tmp.path}/no_such.db',
            archiveBucketsSkipped: 0,
            extras: const BackupExtrasResult());
        // Control: seed a real older summary with a lost key.
        await LocalDb.putComputeFreshness(
            kImportSummaryKey, 'v1:5,0,0,1,1,0,0,1');
        expect((await lastImportSummary())?.needsReentry,
            [kNeedsReentryCoachKey],
            reason: 'control: the older summary reads back');
        await recordImportSummary('${tmp.path}/no_such.db',
            archiveBucketsSkipped: 0,
            extras: const BackupExtrasResult());
        expect((await lastImportSummary())?.needsReentry ?? const [], isEmpty,
            reason: 'the older import\'s warning must not describe this one');
      });
    });
  });

  group('2: the notes are not lost', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('import_round2_');
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('runImport keeps the re-entry list on the app until dismissed',
        () async {
      final app = _App({'a.db': _lost});
      addTearDown(app.importProgress.dispose);
      expect(app.importReentry.value, isEmpty);
      await runImport(app, await _backups(tmp, ['a.db']));
      expect(app.importReentry.value, [kNeedsReentryCoachKey],
          reason: 'set by the run, not by a page that may be gone');
      app.dismissImportReentry();
      expect(app.importReentry.value, isEmpty);
    });

    testWidgets('Your data shows kept notes on a fresh visit and can dismiss',
        (t) async {
      _tall(t);
      var dismissed = 0;
      await t.pumpWidget(_app(DataScreenView(
          pendingReentry: const [kNeedsReentryCoachKey],
          onDismissNotes: () => dismissed++)));
      await t.pump();
      expect(find.byKey(_keyLine), findsOneWidget);
      expect(find.byKey(_deviceLine), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('post-import-dismiss')));
      expect(dismissed, 1);

      await t.pumpWidget(_app(const DataScreenView()));
      await t.pump();
      expect(find.byKey(_keyLine), findsNothing, reason: 'nothing kept, nothing shown');
    });

    testWidgets('Welcome holds the result behind Continue when something '
        'needs re-entering; only Continue completes onboarding', (t) async {
      _tall(t);
      final dir = Directory.systemTemp.createTempSync('welcome_round2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final app = _App({'a.db': _lost});
      addTearDown(app.importProgress.dispose);
      final files = await t.runAsync(() => _backups(dir, ['a.db']));
      FilePicker.platform = _Picker(files!);
      await t.pumpWidget(_app(const WelcomeScreen(), app: app));
      await t.pump();
      await t.tap(find.byType(TextButton).first);
      await t.pump();
      for (var i = 0; i < 20 && find.byKey(_keyLine).evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump();
      }
      expect(find.byKey(_keyLine), findsOneWidget);
      expect(app.onboarded, isEmpty,
          reason: 'the route must not move on before the notes were read');
      final cont = find.byKey(const ValueKey('welcome-import-continue'));
      expect(cont, findsOneWidget);
      await t.tap(cont);
      await t.pump();
      expect(app.onboarded, ['done']);
    });

    testWidgets('Welcome does not hold when nothing needs re-entering',
        (t) async {
      _tall(t);
      final dir = Directory.systemTemp.createTempSync('welcome_round2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final app = _App({'a.db': const ImportSummary()});
      addTearDown(app.importProgress.dispose);
      final files = await t.runAsync(() => _backups(dir, ['a.db']));
      FilePicker.platform = _Picker(files!);
      await t.pumpWidget(_app(const WelcomeScreen(), app: app));
      await t.pump();
      await t.tap(find.byType(TextButton).first);
      await t.pump();
      for (var i = 0; i < 20 && app.onboarded.isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump();
      }
      expect(app.onboarded, ['done']);
      expect(find.byKey(const ValueKey('welcome-import-continue')), findsNothing);
    });
  });

  group('4: copying shows no row counts', () {
    Future<void> pump(WidgetTester t, ImportProgress s, {bool compact = false}) =>
        t.pumpWidget(_app(Scaffold(
            body: ListView(children: [ImportProgressView(s, compact: compact)]))));

    for (final compact in [false, true]) {
      testWidgets('step N of M stays; rowid numbers and "rows" go (compact=$compact)',
          (t) async {
        await pump(t, const ImportCopying(ImportStage.heartRate, 500, 2000, 2, 9),
            compact: compact);
        expect(find.text('Copying heart rate'), findsOneWidget);
        expect(find.textContaining('Step 2 of 9'), findsOneWidget);
        expect(find.textContaining('rows'), findsNothing);
        expect(find.textContaining('2,000'), findsNothing);
        expect(find.textContaining('500'), findsNothing);
      });
    }

    testWidgets('the bar is the monotonic fraction, indeterminate without a total',
        (t) async {
      await pump(t, const ImportCopying(ImportStage.heartRate, 500, 2000, 2, 9));
      expect(find.textContaining('rows'), findsNothing, reason: 'no row label');
      expect(
          t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
          closeTo(0.25, 1e-9));
      await pump(t, const ImportCopying(ImportStage.heartRate, 0, 0, 1, 9));
      expect(find.textContaining('rows'), findsNothing);
      expect(
          t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
          isNull);
    });
  });

  group('6: consent', () {
    testWidgets('restart: a fresh app that loads the stored answer is not asked',
        (t) async {
      SharedPreferences.setMockInitialValues({});
      final first = AppState.forTesting();
      addTearDown(first.importProgress.dispose);
      await t.runAsync(first.loadConsent);
      expect(first.consentLoaded, isTrue);
      expect(first.consentPromptDue, isTrue, reason: 'nothing stored: asked');

      SharedPreferences.setMockInitialValues({'consent_chosen': true});
      final second = AppState.forTesting();
      addTearDown(second.importProgress.dispose);
      await t.runAsync(second.loadConsent);
      expect(second.consentLoaded, isTrue);
      expect(second.consentChosen, isTrue);
      expect(second.consentPromptDue, isFalse);
    });

    testWidgets('a build that offers health-data contribution: off by default, '
        'recorded through its setter', (t) async {
      _tall(t);
      final app = _App({})..consentLoaded = true;
      addTearDown(app.importProgress.dispose);
      await t.pumpWidget(_app(
          const ConsentPromptHost(child: SizedBox()),
          app: app,
          caps: const Capabilities(CapabilityInputs(healthShareBuild: true))));
      await t.pump();
      final health = find.byKey(const ValueKey('consent-health-share'));
      expect(health, findsOneWidget);
      expect(t.widget<Switch>(health).value, isFalse);
      await t.tap(health);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('consent-confirm')));
      await t.pump();
      expect(app.healthCalls, [true]);
      expect(app.telemetryCalls, [false],
          reason: 'telemetry was left off, and that is recorded');
    });
  });
}
