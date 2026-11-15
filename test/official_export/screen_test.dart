import 'export_hooks.dart';
// WHY: target, limitations and recovery choice must stay visible, including
// small dark screens. Proves CLAIM(export-accounted-data/export-verified-save).
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/official_export.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import '../support/bundled_fonts.dart';
import '../backup/backup_support.dart';
import 'fixture.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/destination.dart';
import 'package:openstrap_edge/data/official_export/snapshot.dart';

Future<void> captureExportShot(
  WidgetTester t,
  GlobalKey key,
  String name,
) async {
  await t.runAsync(() async {
    final dir = await Directory(
      'build/export-official-shots',
    ).create(recursive: true);
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key));
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  // WHY: the saved phase must show readable counts from a real production
  // report, including hundreds of repeated omissions. CLAIM(export-accounted-data).
  testWidgets('saved skipped items group a real rich export report', (t) async {
    late OfficialExportSaved saved;
    await t.runAsync(() async {
      final env = await BackupEnv.create('official_screen_report.db');
      try {
        final db = await LocalDb.instance;
        await seedOfficialFixture(db);
        for (var i = 0; i < 312; i++) {
          await db.insert('sessions', {
            ...officialFixtureRows()['sessions']!,
            'id': 'session-$i',
          });
        }
        await db.insert('sessions', {
          'id': 'no-scores',
          'start_ts': 100,
          'end_ts': 200,
          'type': 'running',
          'status': 'done',
          'source': 'manual',
          'created_at': 1,
        });
        await Directory('${env.root.path}/saved').create();
        final result = await OfficialExportCoordinator().export(
          snapshot: const StrictOfficialSnapshot(),
          privateRoot: Directory('${env.root.path}/private'),
          destination: LocalOfficialDestination(
            Directory('${env.root.path}/saved'),
          ),
          passphrase: 'render real export report',
          profileText: await File(
            'assets/official_export/v0.11.3.json',
          ).readAsString(),
          recoveryChoice: TestRecoveryChoice(() async => false),
        );
        expect(
          result,
          isA<OfficialExportSaved>(),
          reason: result is OfficialExportFailed ? result.reason : '',
        );
        saved = result as OfficialExportSaved;
        await Directory('build/export-official-shots').create(recursive: true);
        await File(
          'build/export-official-shots/skipped-report.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert(saved.report.toJson()),
        );
      } finally {
        await env.dispose();
      }
    });
    t.view.physicalSize = const Size(1170, 3300);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    await t.pumpWidget(
      ChangeNotifierProvider(
        create: (_) =>
            ThemeController.seed(AppThemeChoice.dark, Brightness.dark),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark),
          home: RepaintBoundary(
            key: key,
            child: OfficialExportView(
              phase: 'saved',
              savedFiles: saved.names,
              report: saved.report,
            ),
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.textContaining('Files saved and verified'), findsOneWidget);
    await captureExportShot(t, key, 'skipped-real-saved-top');
    await t.scrollUntilVisible(find.text('Skipped items'), 400);
    await t.pumpAndSettle();
    await Scrollable.ensureVisible(
      t.element(find.text('Skipped items')),
      alignment: 0,
    );
    await t.pumpAndSettle();
    expect(
      find.text(
        'Workout scores: 313 workouts. The official app recomputes them.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('session-311'), findsNothing);
    expect(find.textContaining('ecg_reading'), findsNothing);
    expect(find.textContaining('attempt_group'), findsNothing);

    expect(find.text('Choose folder and passphrase'), findsNothing);
    expect(t.takeException(), isNull);
    await captureExportShot(t, key, 'skipped-real-saved');
  });

  for (final state in [
    'ready',
    'running',
    'saved',
    'failed',
    'cancelled',
    'newer',
  ]) {
    testWidgets('dark export $state state', (t) async {
      t.view.physicalSize = const Size(1170, 3300);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final key = GlobalKey();
      await t.pumpWidget(
        ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.dark, Brightness.dark),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark),
            home: RepaintBoundary(
              key: key,
              child: OfficialExportView(
                phase: state,
                onCancel: () {},
                onFreshChanged: (_) {},
                stage: state == 'running'
                    ? 'Expanding lossless archive buckets'
                    : null,
                processed: state == 'running' ? 82 : null,
                message: state == 'failed'
                    ? 'The selected folder could not be read back. No completed file was published.'
                    : null,
                savedFiles: state == 'saved'
                    ? const [
                        'openstrap-official-v0.11.3-pilot.db.osbk',
                        'openstrap-fork-recovery-pilot.db.osbk',
                      ]
                    : const [],
                latestTag: state == 'newer' ? 'v0.12.0' : null,
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.textContaining('v0.11.3'), findsWidgets);
      if (state == 'newer') {
        expect(find.textContaining('A newer official release'), findsOneWidget);
      }
      expect(t.takeException(), isNull);
      await captureExportShot(t, key, state);
    });
  }
  testWidgets('recovery choice defaults to yes and permits decline', (t) async {
    bool? answer;
    final promptKey = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: promptKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark),
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  answer = await askOfficialRecovery(c);
                },
                child: const Text('Ask'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Ask'));
    await t.pumpAndSettle();
    expect(
      find.text(
        "Save a second file with data the official version doesn't yet support?",
      ),
      findsOneWidget,
    );
    expect(
      t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await captureExportShot(t, promptKey, 'recovery-choice');
    await t.tap(find.byType(CheckboxListTile));
    await t.pump();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(answer, isFalse);
  });
  testWidgets('small screen and larger text keep the export action reachable', (
    t,
  ) async {
    t.view.physicalSize = const Size(1080, 2520);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    var started = false;
    final key = GlobalKey();
    await t.pumpWidget(
      ChangeNotifierProvider(
        create: (_) =>
            ThemeController.seed(AppThemeChoice.dark, Brightness.dark),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(1.3)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: key,
            child: OfficialExportView(
              fresh: true,
              onFreshChanged: (_) {},
              onStart: () => started = true,
            ),
          ),
        ),
      ),
    );
    await t.scrollUntilVisible(find.text('Choose folder and passphrase'), 400);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await captureExportShot(t, key, 'ready-small-bottom');
    await t.tap(find.text('Choose folder and passphrase'));
    expect(started, isTrue);
  });
}
