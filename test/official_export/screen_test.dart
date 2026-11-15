// WHY: target, limitations and recovery choice must stay visible, including
// small dark screens. Proves CLAIM(export-accounted-data/export-verified-save).
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/official_export.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import '../support/bundled_fonts.dart';

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
  for (final state in [
    'ready',
    'running',
    'saved',
    'skipped',
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
                skipLines: state == 'skipped'
                    ? const [
                        'water_moment: 18 records. Official importer does not support this table.',
                        'ecg_reading.attempt_group: 4 values. Attempt grouping stays in recovery.',
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
