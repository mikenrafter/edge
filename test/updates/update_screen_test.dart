// WHY: the screen is where consent is given and where an install would be
// offered if one ever came back. It must name the disclosure, show both
// sources independently and offer only release pages.
// Proves CLAIM(release-check-consent), CLAIM(release-check-page-only).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/sync/update_background.dart' show updateTaskFrequency, updateTaskNetworkType;
import 'package:openstrap_edge/sync/update_coordinator.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/sync/update_models.dart';
import 'package:openstrap_edge/ui2/profile/app_updates.dart';

Widget host(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: child),
);

void main() {
  // catches: a Settings row that says nothing about state, or hides the
  // separate-app relationship that keeps the user's data where it is.
  testWidgets('the Settings row names the feature and the newest release', (t) async {
    await t.pumpWidget(host(AppUpdatesRow(
      snapshot: UpdateSnapshot(
        enabled: true,
        phase: UpdatePhase.available,
        sources: {
          ReleaseSource.official: SourceUpdate(
            candidate: ReleaseCandidate(
              source: ReleaseSource.official,
              id: 9,
              tag: 'v0.12.3',
              asset: 'openstrap-edge-v0.12.3.apk',
              prerelease: false,
              relation: ReleaseRelation.officialSeparateApp,
            ),
            checkedAt: DateTime.utc(2026, 11, 15),
          ),
        },
      ),
    )));
    expect(find.text('App updates'), findsOneWidget);
    expect(find.textContaining('v0.12.3'), findsOneWidget);
    expect(find.textContaining('Separate app'), findsOneWidget);
  });

  testWidgets('a current install says so and offers the cached official page only', (t) async {
    await t.pumpWidget(host(AppUpdatesRow(
      snapshot: UpdateSnapshot(
        enabled: true,
        phase: UpdatePhase.current,
        sources: {
          ReleaseSource.official: SourceUpdate(
            candidate: ReleaseCandidate(
              source: ReleaseSource.official, id: 1, tag: 'v0.12.2',
              asset: 'a.apk', prerelease: false,
              relation: ReleaseRelation.officialInformational),
            checkedAt: DateTime.utc(2026, 11, 15),
          ),
        },
      ),
    )));
    expect(find.text('Up to date'), findsOneWidget);
  });

  // WHY: spec §5.1 - periodic work only on unmetered, daily, best effort.
  test('periodic registration is daily and unmetered', () {
    expect(updateTaskFrequency, const Duration(days: 1));
    expect(updateTaskNetworkType, NetworkType.unmetered);
  });

  group('screen', () {
    late _Service service;
    var settingsOpened = 0;
    setUp(() {
      service = _Service();
      settingsOpened = 0;
      AppUpdatesScreen.openExport = null;
    });
    tearDown(() {
      NotificationService.instance.debugRequestPermission = null;
      service.dispose();
    });
    Widget screen({ReleaseAlertAccess access = ReleaseAlertAccess.granted}) =>
        host(AppUpdatesScreen(
          service: service,
          access: () async => access,
          openAppSettings: () async => settingsOpened++,
        ));

    // catches: disabling the opt-out switch for the whole request.
    testWidgets('opt-out stays usable during a pending Check now', (t) async {
      await t.pumpWidget(screen());
      await t.ensureVisible(find.text('Check now'));
      await t.tap(find.text('Check now'));
      await t.pump();
      expect(service.snapshot.phase, UpdatePhase.checking);
      await t.ensureVisible(find.byType(Switch).first);
      await t.tap(find.byType(Switch).first);
      await t.pump();
      expect(service.choices, [false]);
      service.pending.complete();
      await t.pump();
    });

    // WHY: enabling checks authorizes no OS dialog; only this tap may prompt.
    testWidgets('permission is requested only by the explicit foreground button', (t) async {
      var prompts = 0;
      NotificationService.instance.debugRequestPermission = () async {
        prompts++;
        return true;
      };
      await t.pumpWidget(screen(access: ReleaseAlertAccess.denied));
      await t.pump();
      expect(prompts, 0);
      expect(find.textContaining('Update notifications are off'), findsOneWidget);
      await t.ensureVisible(find.text('Allow update notifications'));
      await t.tap(find.text('Allow update notifications'));
      await t.pump();
      expect(prompts, 1);
    });

    // catches: a muted channel shown as working notifications.
    testWidgets('muted channel and denied state each offer the settings action', (t) async {
      await t.pumpWidget(screen(access: ReleaseAlertAccess.channelMuted));
      await t.pump();
      expect(find.textContaining('muted'), findsOneWidget);
      await t.ensureVisible(find.text('Open notification settings'));
      await t.tap(find.text('Open notification settings'));
      expect(settingsOpened, 1);
      expect(find.text('Allow update notifications'), findsNothing);
    });

    // WHY: owner rule NO INSTALLS. catches: any download/install action returning.
    testWidgets('no install, download or APK action anywhere', (t) async {
      service.snapshot = UpdateSnapshot(
        enabled: true,
        phase: UpdatePhase.available,
        sources: {
          ReleaseSource.fork: SourceUpdate(
            candidate: ReleaseCandidate(
              source: ReleaseSource.fork, id: 5, tag: 'next-2026.11.15',
              asset: 'openstrap-edge-next-2026.11.15-dev-profile.apk',
              prerelease: true, build: 99, relation: ReleaseRelation.forkNewer),
            checkedAt: DateTime.utc(2026, 11, 15)),
        },
      );
      await t.pumpWidget(screen());
      await t.pump();
      final text = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');
      expect(RegExp(r'install|download|\.apk', caseSensitive: false).hasMatch(text), isFalse, reason: text);
      expect(find.text('Open release page'), findsWidgets);
    });

    testWidgets('an unidentified install gets an explanation and two page links, no switches', (t) async {
      service.supportedOverride = false;
      await t.pumpWidget(screen());
      await t.pump();
      expect(find.textContaining("can’t check for updates itself"), findsOneWidget);
      expect(find.text('Open release page'), findsNWidgets(2));
      expect(find.byType(Switch), findsNothing);
    });

    // catches: P3's export entry shown (or crashing) before its route exists.
    testWidgets('the export entry appears only when the shared route is registered', (t) async {
      service.snapshot = UpdateSnapshot(
        enabled: true,
        phase: UpdatePhase.available,
        sources: {
          ReleaseSource.official: SourceUpdate(
            candidate: ReleaseCandidate(
              source: ReleaseSource.official, id: 3, tag: 'v0.12.3',
              asset: 'a.apk', prerelease: false,
              relation: ReleaseRelation.officialSeparateApp),
            checkedAt: DateTime.utc(2026, 11, 15)),
        },
      );
      await t.pumpWidget(screen());
      await t.pump();
      expect(find.text('Move your data to the official app'), findsNothing);
      bool? news;
      DateTime? at;
      AppUpdatesScreen.openExport = (c, {bool newerOfficialAvailable = false, DateTime? checkedAt}) {
        news = newerOfficialAvailable;
        at = checkedAt;
      };
      await t.pumpWidget(screen());
      await t.pump();
      final entry = find.widgetWithText(TextButton, 'Move your data to the official app');
      await t.ensureVisible(entry);
      await t.pumpAndSettle();
      await t.tap(entry);
      await t.pump();
      expect(news, isTrue);
      expect(at, DateTime.utc(2026, 11, 15));
    });

    // WHY: 48 dp targets and no overflow at 320 dp / 2x text, English, Thai, Russian.
    for (final locale in ['en', 'th', 'ru']) {
      testWidgets('lays out at 320 dp and 2x text in $locale', (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(320, 640);
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        service.snapshot = UpdateSnapshot(
          enabled: true,
          phase: UpdatePhase.error,
          sources: {
            ReleaseSource.official: SourceUpdate(
              error: UpdateError.rateLimited,
              retryAt: DateTime.utc(2026, 11, 16),
              releasePage: ReleasePage.forRelease(ReleaseSource.official, 'v0.12.3')),
            ReleaseSource.fork: SourceUpdate(error: UpdateError.noAsset),
          },
        );
        await t.pumpWidget(MediaQuery(
          data: const MediaQueryData(size: Size(320, 640), textScaler: TextScaler.linear(2)),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale(locale),
            home: AppUpdatesScreen(service: service, access: () async => ReleaseAlertAccess.granted),
          ),
        ));
        await t.pump();
        expect(t.takeException(), isNull);
        for (final b in t.widgetList(find.byType(TextButton))) {
          final size = t.getSize(find.byWidget(b));
          expect(size.height, greaterThanOrEqualTo(48));
        }
      });
    }
  });
}

class _NoDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Service extends UpdateCoordinator {
  _Service()
    : super(
        store: UpdateStore(_NoDatabase()),
        client: MockClient((_) async => http.Response('[]', 200)),
        installed: const InstalledRelease(version: '0.11.3', build: 78, fork: true, mode: 'profile'),
        now: DateTime.now,
        unmetered: () async => true,
        schedule: (_) async {},
      ) {
    snapshot = const UpdateSnapshot(enabled: true, phase: UpdatePhase.notChecked);
  }
  final pending = Completer<void>();
  final choices = <bool>[];
  bool supportedOverride = true;
  @override
  bool get supported => supportedOverride;
  @override
  Future<CheckOutcome> check({bool manual = false}) async {
    snapshot = const UpdateSnapshot(enabled: true, phase: UpdatePhase.checking);
    notifyListeners();
    await pending.future;
    return const CheckCompleted();
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    choices.add(enabled);
    snapshot = UpdateSnapshot(enabled: enabled);
    notifyListeners();
  }
}
