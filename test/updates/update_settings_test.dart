// WHY: every checker state stays visible in Settings, wraps at large text, and
// gives an actionable reason rather than claiming current from missing input.
// Proves CLAIM(update-honest-state). PNGs are evidence, not auto-approved goldens.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'update_checker_test.dart' show release;
import 'update_review_regressions_test.dart' show manifest, forkRelease;
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/sync/update_service.dart';
import 'package:openstrap_edge/ui2/profile/app_updates.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../support/bundled_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    'official-news': const UpdateSnapshot(
      enabled: true,
      phase: UpdatePhase.available,
      sources: {
        ReleaseSource.official: SourceUpdate(
          candidate: ReleaseCandidate(
            source: ReleaseSource.official,
            separateApp: true,
            id: 3,
            tag: 'v0.11.4',
            asset: 'openstrap-edge-v0.11.4.apk',
            prerelease: false,
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
  setUpAll(() async {
    await loadFonts();
    // WHY: B1's former screenshot was hand-built and unreachable from the
    // actual .dev package's profile versionName. Discover and reload it through
    // the production service before using it in either Settings or screen shots.
    states['current'] = await _discoverCurrentProfileFork();
  });
  // WHY: B1 must label a new official release as a separate app, including the
  // compact Settings entry. The production selector supplies the relationship.
  // catches: reusing the in-place Update available title for official news.
  test('official news summary identifies the separate app', () async {
    final candidate = selectRelease(
      ReleaseSource.official,
      [
        {
          'id': 1,
          'tag_name': 'v0.11.4',
          'draft': false,
          'prerelease': false,
          'assets': [
            {'id': 10, 'name': 'openstrap-edge-v0.11.4.apk'},
          ],
        },
      ],
      const InstalledRelease(
        version: '0.11.3-dev',
        build: 78,
        fork: true,
        mode: 'profile',
      ),
    )!;
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(updateSummary(l, states['current']!), 'Up to date');
    expect(
      updateSummary(
        l,
        UpdateSnapshot(
          enabled: true,
          phase: UpdatePhase.available,
          sources: {ReleaseSource.official: SourceUpdate(candidate: candidate)},
        ),
      ),
      'New official app release · Official · v0.11.4 · Release · Separate app. Your data stays here.',
    );
  });

  // WHY: the first pilot only captured the Settings entry. Exercise the real
  // screen with both source cards, consent, toggles and the metered dialog.
  // catches: card/text overflow or missing separation at large text sizes.
  testWidgets('dark App updates screen and metered dialog captures', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 844);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final out = Platform.environment['UPDATE_SHOTS'];
    for (final scale in [1.0, 2.0]) {
      for (final name in ['off', 'current', 'official-news']) {
        final snapshot = name == 'official-news'
            ? UpdateSnapshot(
                enabled: true,
                phase: UpdatePhase.available,
                sources: {
                  ...states['current']!.sources,
                  ReleaseSource.official: SourceUpdate(
                    candidate: selectRelease(
                      ReleaseSource.official,
                      [
                        {
                          'id': 3,
                          'tag_name': 'v0.11.4',
                          'draft': false,
                          'prerelease': false,
                          'assets': [
                            {'id': 11, 'name': 'openstrap-edge-v0.11.4.apk'},
                          ],
                        },
                      ],
                      const InstalledRelease(
                        version: '0.11.3-dev',
                        build: 78,
                        fork: true,
                        mode: 'profile',
                      ),
                    ),
                  ),
                },
              )
            : states[name]!;
        final service = _CaptureService(snapshot);
        final key = GlobalKey();
        await t.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.dark),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: AppUpdatesScreen(service: service),
            ),
          ),
        );
        await t.pumpAndSettle();
        final suffix = scale == 1 ? 'normal' : 'large';
        await capture(t, key, out, 'screen-$name-top-$suffix');
        await t.scrollUntilVisible(
          find.text('mikenrafter/edge'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          t.element(
            find.ancestor(
              of: find.text('mikenrafter/edge'),
              matching: find.byType(Card),
            ),
          ),
          alignment: 0.5,
        );
        await t.pumpAndSettle();
        await capture(t, key, out, 'screen-$name-fork-$suffix');
        await t.scrollUntilVisible(
          find.text('OpenStrap/edge'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          t.element(
            find.ancestor(
              of: find.text('OpenStrap/edge'),
              matching: find.byType(Card),
            ),
          ),
          alignment: 0.5,
        );
        await t.pumpAndSettle();
        expect(
          find.text('Open release page'),
          name == 'off' ? findsNothing : findsWidgets,
        );
        await capture(t, key, out, 'screen-$name-official-$suffix');
        if (name == 'current') {
          await t.scrollUntilVisible(
            find.text('Check now'),
            -300,
            scrollable: find.byType(Scrollable).first,
          );
          await Scrollable.ensureVisible(
            t.element(find.text('Check now')),
            alignment: 0.5,
          );
          await t.pumpAndSettle();
          await t.tap(find.text('Check now'));
          await t.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          await capture(t, key, out, 'screen-metered-$suffix');
          await t.tap(find.text('Cancel'));
          await t.pumpAndSettle();
        }
        expect(t.takeException(), isNull, reason: '$name $scale');
        await t.pumpWidget(const SizedBox());
        service.dispose();
      }
    }
  });

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

Future<void> capture(
  WidgetTester t,
  GlobalKey key,
  String? out,
  String name,
) async {
  expect(t.takeException(), isNull, reason: name);
  if (out == null) return;
  await t.runAsync(() async {
    final boundary = t.renderObject(find.byKey(key)) as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(out).create(recursive: true);
    await File('$out/dark-$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _CaptureService extends UpdateService {
  _CaptureService(UpdateSnapshot state)
    : super(
        store: UpdateStore(_NoDatabase()),
        client: MockClient((_) async => http.Response('[]', 200)),
        installed: const InstalledRelease(
          version: '0.11.3-dev',
          build: 78,
          fork: true,
          mode: 'profile',
        ),
        now: () => DateTime.utc(2026, 11, 15, 12),
        unmetered: () async => false,
        schedule: (_) async {},
      ) {
    snapshot = state;
  }
}

class _NoDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<UpdateSnapshot> _discoverCurrentProfileFork() async {
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('update-capture-');
  final store = UpdateStore(
    await databaseFactoryFfi.openDatabase('${directory.path}/updates.db'),
  );
  final service = UpdateService(
    store: store,
    client: MockClient(
      (r) async => http.Response(
        jsonEncode(
          r.url.path.contains('/assets/')
              ? manifest('next-2026.11.15')
              : r.url.path.contains('OpenStrap')
              ? [release('v0.11.3')]
              : [forkRelease('next-2026.11.15')],
        ),
        200,
      ),
    ),
    // UpdateService.create maps wtf.openstrap.openstrap_edge.dev to fork: true;
    // PackageInfo retains Gradle's literal profile versionName and build number.
    installed: const InstalledRelease(
      version: '0.11.3-dev',
      build: 78,
      fork: true,
      mode: 'profile',
    ),
    now: () => DateTime.utc(2026, 11, 15, 12),
    unmetered: () async => true,
    schedule: (_) async {},
  );
  try {
    await store.initialize();
    await service.setEnabled(true);
    await service.check();
    expect(service.snapshot.phase, UpdatePhase.current);
    await service.load();
    expect(service.snapshot.phase, UpdatePhase.current);
    expect(service.snapshot.sources[ReleaseSource.fork]!.current, isTrue);
    expect(service.snapshot.sources[ReleaseSource.official]!.current, isTrue);
    expect(
      service.snapshot.sources[ReleaseSource.official]!.candidate!.separateApp,
      isTrue,
    );
    return service.snapshot;
  } finally {
    service.dispose();
    await store.db.close();
    await directory.delete(recursive: true);
  }
}
