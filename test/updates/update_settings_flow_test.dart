// WHY: consent can be withdrawn while GitHub is slow; background work cannot
// leave the foreground switch disabled. Proves CLAIM(update-network-consent).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/sync/update_service.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:openstrap_edge/ui2/profile/app_updates.dart';
import 'package:openstrap_edge/ui2/theme.dart';

// The widget is the unit here; this controllable controller keeps the network
// pending. Coordinator persistence and cancellation use real SQLite elsewhere.
class _PendingService extends UpdateService {
  _PendingService()
    : super(
        store: UpdateStore(_NoDatabase()),
        client: MockClient((_) async => http.Response('[]', 200)),
        installed: const InstalledRelease(
          version: '0.11.3',
          build: 78,
          fork: true,
          mode: 'profile',
        ),
        now: DateTime.now,
        unmetered: () async => true,
        schedule: (_) async {},
      ) {
    snapshot = const UpdateSnapshot(
      enabled: true,
      phase: UpdatePhase.notChecked,
    );
  }
  final pending = Completer<void>();
  final choices = <bool>[];
  @override
  Future<void> check({bool manual = false}) {
    snapshot = const UpdateSnapshot(enabled: true, phase: UpdatePhase.checking);
    notifyListeners();
    return pending.future;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    choices.add(enabled);
    snapshot = UpdateSnapshot(enabled: enabled);
    notifyListeners();
  }
}

class _NoDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Widget app(UpdateService service) => MaterialApp(
  theme: buildTheme(Brightness.dark),
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: AppUpdatesScreen(service: service),
);

void main() {
  // catches: disabling the opt-out switch for the whole network request.
  testWidgets('opt-out stays usable during a pending Check now', (t) async {
    final service = _PendingService();
    await t.pumpWidget(app(service));
    await t.ensureVisible(find.text('Check now'));
    await t.tap(find.text('Check now'));
    await t.pump();
    expect(service.snapshot.phase, UpdatePhase.checking);
    await t.ensureVisible(find.byType(Switch).first);
    await t.tap(find.byType(Switch).first);
    await t.pump();
    expect(service.choices, [false]);
    expect(service.snapshot.enabled, isFalse);
    service.pending.complete();
    await t.pump();
    await t.pumpWidget(const SizedBox());
    service.dispose();
  });

  // WHY: an automatic check grants no permission to show an OS dialog.
  // catches: permission prompts on opening the page instead of a foreground tap.
  testWidgets(
    'permission is requested only by the explicit foreground button',
    (t) async {
      final service = _PendingService();
      var prompts = 0;
      NotificationService.instance.debugRequestPermission = () async {
        prompts++;
        return true;
      };
      await t.pumpWidget(app(service));
      expect(prompts, 0);
      await t.ensureVisible(find.text('Allow update notifications'));
      await t.tap(find.text('Allow update notifications'));
      await t.pump();
      expect(prompts, 1);
      await t.pumpWidget(const SizedBox());
      NotificationService.instance.debugRequestPermission = null;
      service.dispose();
    },
  );
}
