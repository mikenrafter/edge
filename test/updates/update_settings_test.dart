// WHY: every checker state stays visible in Settings, wraps at large text, and
// gives an actionable reason rather than claiming current from missing input.
// Proves CLAIM(update-honest-state). PNGs are evidence, not auto-approved goldens.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/sync/update_service.dart';
import 'package:openstrap_edge/ui2/profile/app_updates.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../support/bundled_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  final states = <String, UpdateSnapshot>{
    'off': const UpdateSnapshot(),
    'not-checked': const UpdateSnapshot(
      enabled: true,
      phase: UpdatePhase.notChecked,
    ),
    'checking': const UpdateSnapshot(
      enabled: true,
      phase: UpdatePhase.checking,
    ),
    'current': const UpdateSnapshot(enabled: true, phase: UpdatePhase.current),
    'available': const UpdateSnapshot(
      enabled: true,
      phase: UpdatePhase.available,
      sources: {
        ReleaseSource.fork: SourceUpdate(
          candidate: ReleaseCandidate(
            source: ReleaseSource.fork,
            id: 123,
            tag: 'next-2026.11.15',
            prerelease: true,
            build: 79,
            asset: 'openstrap-edge-next-2026.11.15-dev-profile.apk',
          ),
        ),
      },
    ),
    'error': const UpdateSnapshot(
      enabled: true,
      phase: UpdatePhase.error,
      sources: {
        ReleaseSource.official: SourceUpdate(error: UpdateError.rateLimited),
      },
    ),
    'waiting': const UpdateSnapshot(
      enabled: true,
      phase: UpdatePhase.notChecked,
      waiting: true,
    ),
  };
  // catches: clipping/error omissions and a source label that disappears in translation.
  testWidgets('dark Settings rows in every state and all seven locales', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 480);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final out = Platform.environment['UPDATE_SHOTS'];
    for (final locale in AppLocalizations.supportedLocales) {
      for (final scale in [1.0, 2.0]) {
        for (final state in states.entries) {
          var taps = 0;
          final key = GlobalKey();
          await t.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.dark),
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  body: Builder(
                    builder: (c) => MediaQuery(
                      data: MediaQuery.of(
                        c,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          const SizedBox(height: 20),
                          Text(
                            AppLocalizations.of(c)!.settingsNavTitle,
                            style: F.head,
                          ),
                          const SizedBox(height: 24),
                          AppUpdatesRow(
                            snapshot: state.value,
                            onTap: () => taps++,
                          ),
                          const Divider(),
                          SetRow(
                            LucideIcons.bell,
                            C.blue,
                            AppLocalizations.of(c)!.updatesPermission,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(
            t.takeException(),
            isNull,
            reason: '${locale.languageCode} ${state.key} $scale',
          );
          final l = await AppLocalizations.delegate.load(locale);
          expect(find.text(l.updatesTitle), findsOneWidget);
          expect(find.text(updateSummary(l, state.value)), findsOneWidget);
          await t.tap(find.byType(AppUpdatesRow));
          expect(taps, 1);
          if (out != null && locale.languageCode == 'en') {
            await t.runAsync(() async {
              final boundary =
                  t.renderObject(find.byKey(key)) as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(out).create(recursive: true);
              await File(
                '$out/dark-${state.key}-${scale == 1 ? 'normal' : 'large'}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      }
    }
  });
}
