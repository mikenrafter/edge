// Review round on the import spinner: a retained ImportFailed must not leak
// into the app-wide StatusLine or hide the next action's progress/result, the
// replaced Import row keeps its real height at large text and long
// translations, and the compact spinner fits its row in every state.
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/status_line.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;


class _App extends AppState {
  _App() : super.forTesting();
  Completer<BackupOutcome>? backup;
  @override
  DateTime? get lastRecordAt => DateTime(2026, 10, 4, 11, 6);
  @override
  Future<BackupOutcome> runBackupNow() => backup!.future;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

void _size(WidgetTester t, double w, [double h = 6000]) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget _app(Widget home,
        {double scale = 1, Locale? locale, AppState? app}) {
  Widget h = home;
  if (app != null) {
    h = ChangeNotifierProvider<AppState>.value(value: app, child: h);
  }
  return MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: h,
  );
}

const _failed = ImportFailed('disk full');

class _Picker extends FilePicker with MockPlatformInterfaceMixin {
  _Picker({this.error, this.path});
  final Object? error;
  final String? path;
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
  }) async {
    if (error != null) throw error!;
    return FilePickerResult([PlatformFile(name: 'x.csv', size: 0, path: path)]);
  }
}

/// Retained backup failure, then a second import attempt whose error does not
/// come from importEdgeBackup: the NEW error must show.
Future<void> _retryAfterFailed(WidgetTester t, FilePicker picker) async {
  _size(t, 800);
  FilePicker.platform = picker;
  final app = _App();
  addTearDown(app.importProgress.dispose);
  // A real retained backup failure (AppState keeps it apart from the notifier,
  // so a CSV import can hand it back).
  await t.runAsync(() => app
      .importEdgeBackup('${Directory.systemTemp.path}/os_no_such_backup.db')
      .then<void>((_) {}, onError: (_) {}));
  expect(app.importProgress.value, isA<ImportFailed>());
  await t.pumpWidget(_app(const DataScreen(), app: app));
  await _settle(t);
  await t.tap(find.text('Import a file'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  for (var i = 0; i < 50; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump();
    // A CSV import now publishes its own progress too: wait for that as well.
    final v = app.importProgress.value;
    final active = v != null && v is! ImportFailed && v is! ImportDone;
    if (!active && find.text('Importing your history').evaluate().isEmpty) break;
  }
  await _settle(t);
  expect(find.textContaining('Backup file not found'), findsOneWidget,
      reason: 'the retained backup failure stays');
}

void main() {
  group('1: a retained failure is not "busy" for the StatusLine', () {
    for (final syncActions in [false, true]) {
      testWidgets('falls through to Synced through (syncActions=$syncActions)',
          (t) async {
        final app = _App();
        addTearDown(app.importProgress.dispose);
        app.importProgress.value = _failed;
        await t.pumpWidget(_app(
            Scaffold(
                body: StatusLine(
                    todayId: '2026-10-04',
                    now: DateTime(2026, 10, 4, 12),
                    syncActions: syncActions)),
            app: app));
        await t.pump();
        expect(find.textContaining('disk full'), findsNothing);
        expect(find.textContaining('Synced through'), findsOneWidget);
        if (syncActions) expect(find.text('Sync now'), findsOneWidget);
      });
    }
  });

  group('2: the next action shows its own progress and result', () {
    testWidgets('Back up now after a failed import', (t) async {
      _size(t, 800);
      final app = _App()..backup = Completer<BackupOutcome>();
      addTearDown(app.importProgress.dispose);
      app.importProgress.value = _failed;
      await t.pumpWidget(_app(const DataScreen(), app: app));
      await _settle(t);
      await t.tap(find.text('Back up now'));
      await _settle(t);
      expect(find.text('Writing the backup'), findsOneWidget,
          reason: 'running status of the current action');
      expect(find.textContaining('disk full'), findsOneWidget);
      app.backup!.complete(const BackupOutcome(path: '/tmp/b.db'));
      await _settle(t);
      expect(find.textContaining('Backed up to /tmp/b.db'), findsOneWidget);
    });

    testWidgets('the failed import itself is reported once', (t) async {
      _size(t, 800);
      await t.pumpWidget(_app(DataScreenView(
          importProgress: _failed,
          note: 'Failed: disk full',
          noteFailed: true,
          noteIsImport: true)));
      await _settle(t);
      expect(find.textContaining('disk full'), findsOneWidget);
    });
  });

  group('2b: a new import error is not hidden by the retained failure', () {
    testWidgets('picker error', (t) async {
      await _retryAfterFailed(t, _Picker(error: 'no picker here'));
      expect(find.textContaining('no picker here'), findsOneWidget);
    });

    testWidgets('non-backup (CSV) import error', (t) async {
      final f = File('${Directory.systemTemp.path}/os_bad_${t.hashCode}.csv');
      await t.runAsync(() => f.writeAsString('not,a,known\nexport,at,all\n'));
      addTearDown(() => f.existsSync() ? f.deleteSync() : null);
      await _retryAfterFailed(t, _Picker(path: f.path));
      expect(find.text('That did not work'), findsOneWidget);
      expect(find.textContaining('None of those files'), findsOneWidget);
    });
  });

  group('3: the replaced row keeps its real height', () {
    for (final (scale, locale) in [
      (1.3, null),
      (2.0, null),
      (1.0, const Locale('de')),
      (2.0, const Locale('de')),
    ]) {
      testWidgets('next row does not move at ${scale}x ${locale ?? 'en'}',
          (t) async {
        _size(t, 390);
        final next = find.byWidgetPredicate((w) =>
            w is Text && (w.data == 'From your phone' || w.data == 'Von deinem Telefon'));
        Future<double> top(ImportProgress? p) async {
          await t.pumpWidget(_app(
              DataScreenView(
                  busy: p != null && p is! ImportDone,
                  importProgress: p,
                  onImport: () {}, onPhoneImport: () {}),
              scale: scale,
              locale: locale));
          await _settle(t);
          expect(find.byType(Text), findsWidgets);
          return t.getTopLeft(find.descendant(
              of: find.byType(DataScreenView),
              matching: next.evaluate().isNotEmpty
                  ? next
                  : find.textContaining('hone'))).dy;
        }

        final before = await top(null);
        final during = await top(const ImportCopying(ImportStage.heartRate, 5, 20, 2, 9));
        final after = await top(const ImportDone());
        expect(during, closeTo(before, 0.5));
        expect(after, closeTo(before, 0.5));
      });
    }
  });

  group('4: compact spinner fits its row', () {
    final states = <ImportProgress>[
      const ImportPreparing(ImportPrepStep.opening),
      const ImportPreparing(ImportPrepStep.inflating),
      const ImportCopying(ImportStage.archive, 500, 2000, 8, 9),
      const ImportRebuilding(0, 0, null),
      const ImportRebuilding(3, 12, '2026-10-01'),
      _failed,
    ];
    for (final w in [390.0, 820.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('no overflow at ${w}pt ${scale}x', (t) async {
          _size(t, w);
          for (final s in states) {
            await t.pumpWidget(_app(
                DataScreenView(
                    busy: s is! ImportFailed,
                    importProgress: s,
                    onImport: () {}),
                scale: scale));
            await _settle(t);
            expect(t.takeException(), isNull, reason: '$s');
          }
        });
      }
    }
  });
}
