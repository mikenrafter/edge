import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/apk1_keys.dart';
import 'support/pin_tz.dart';

final _toggle = find.byKey(const ValueKey<String>(apk1SettingsToggle));
final _cog = find.byKey(const ValueKey<String>(apk1SettingsTab));
final _profile = find.bySemanticsLabel('Profile and settings');

Finder get _tabs => find.descendant(of: apk1TabBar, matching: find.byType(Pressable));

Future<void> _openSettings(WidgetTester t) async {
  expect(_profile, findsOneWidget);
  await t.tap(_profile);
  await apk1Settle(t);
  expect(find.byType(MoreSettings), findsOneWidget);
}

Future<void> _change(WidgetTester t) async {
  // You & preferences is expanded on the first visit, like the existing UI
  // preferences. The key names a real tap target, not the switch's label.
  await apk1Reveal(t, _toggle);
  expect(_toggle, findsOneWidget);
  expect(find.descendant(of: _toggle, matching: find.text('Settings as tab')), findsOneWidget);
  await t.tap(_toggle);
  await apk1Settle(t);
  expect(t.takeException(), isNull);
}

Future<void> _returnToShell(WidgetTester t, Apk1Routes routes) async {
  if (routes.routes.length > 1) {
    await t.binding.handlePopRoute();
    await apk1Settle(t);
  }
  expect(apk1TabBar, findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('apk1_settings.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  for (final scale in [1.0, 3.1]) {
    apk1Test('default four tabs and profile gain a cog immediately when enabled at $scale', (t) async {
      final routes = Apk1Routes();
      await apk1Mount(t, routes: routes, scale: scale);
      expect(_tabs, findsNWidgets(4));
      expect(_cog, findsNothing);
      expect(_profile, findsOneWidget);
      expect((await SharedPreferences.getInstance()).getBool(apk1SettingsPref), isNull);
      await _openSettings(t);
      await _change(t);
      await _returnToShell(t, routes);
      expect(_tabs, findsNWidgets(5));
      expect(_cog, findsOneWidget);
      expect(find.descendant(of: _cog, matching: find.byIcon(LucideIcons.settings)), findsOneWidget);
      expect(_profile, findsNothing);
      expect((await SharedPreferences.getInstance()).getBool(apk1SettingsPref), isTrue);
      for (final domain in ShellDomain.values) {
        final tab = find.descendant(of: apk1TabBar, matching: find.text(domain.label));
        await t.tap(tab);
        await apk1Settle(t);
        expect(_profile, findsNothing,
            reason: '${domain.label} must remove its header profile button too');
        expect(t.takeException(), isNull);
      }
      final depth = routes.routes.length;
      final pushes = routes.pushes;
      await t.tap(_cog);
      await apk1Settle(t);
      expect(find.byType(MoreSettings), findsOneWidget);
      expect(apk1Selected(t), 4);
      expect(routes.routes, hasLength(depth));
      expect(routes.pushes, pushes);
      expect(t.getSemantics(_cog), isSemantics(
        label: 'Settings', isSelected: true, isButton: true,
        hasTapAction: true,
      ));
      expect(t.takeException(), isNull);
    });

    apk1Test('turning off the selected cog returns to a valid domain and restores profile at $scale', (t) async {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(apk1SettingsPref, true);
      final routes = Apk1Routes();
      await apk1Mount(t, routes: routes, scale: scale);
      expect(_tabs, findsNWidgets(5));
      expect(_cog, findsOneWidget);
      expect(_profile, findsNothing);
      await t.tap(_cog);
      await apk1Settle(t);
      expect(apk1Selected(t), 4);
      await _change(t);
      expect(_tabs, findsNWidgets(4));
      expect(_cog, findsNothing);
      expect(apk1Selected(t), inInclusiveRange(0, 3),
          reason: 'removing the current tab must not leave an invalid index');
      expect(_profile, findsOneWidget);
      expect(sp.getBool(apk1SettingsPref), isFalse);
      expect(routes.routes, hasLength(1));
      expect(t.takeException(), isNull);

      await t.pumpWidget(const SizedBox());
      await apk1Mount(t, scale: scale);
      expect(_tabs, findsNWidgets(4));
      expect(_profile, findsOneWidget, reason: 'off persists across remount');
    });
  }

  apk1Test('importing settings-as-tab refreshes the mounted shell without a remount', (t) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(apk1SettingsPref, true);
    final path = await t.runAsync(() => LocalDb.exportCopy());
    expect(path, isNotNull);
    await sp.remove(apk1SettingsPref);
    await apk1Mount(t);
    final shell = t.state(find.byType(AppShell));
    expect(_tabs, findsNWidgets(4));
    expect(_cog, findsNothing);
    expect(_profile, findsOneWidget);

    await t.runAsync(() => LocalDb.importFromDbFile(path!));
    await apk1Settle(t);
    expect(sp.getBool(apk1SettingsPref), isTrue);
    expect(t.state(find.byType(AppShell)), same(shell));
    expect(_tabs, findsNWidgets(5));
    expect(_cog, findsOneWidget);
    expect(_profile, findsNothing);
    await t.tap(_cog);
    await apk1Settle(t);
    expect(find.byType(MoreSettings), findsOneWidget);
    expect(apk1Selected(t), 4);
    expect(t.takeException(), isNull);
  });

  apk1Test('the UI-written settings-as-tab pref survives a full export and import', (t) async {
    final routes = Apk1Routes();
    await apk1Mount(t, routes: routes);
    await _openSettings(t);
    await _change(t);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(apk1SettingsPref), isTrue,
        reason: 'export the actual UI write, not a test-seeded arbitrary key');
    await t.pumpWidget(const SizedBox());
    final path = await t.runAsync(() async {
      await env.seedData();
      return LocalDb.exportCopy();
    });
    expect(path, isNotNull);
    final carried = await t.runAsync(() => exportedPrefs(path!));
    expect(carried, isNotNull);
    expect(carried![apk1SettingsPref], ('bool', 'true'));
    await sp.remove(apk1SettingsPref);
    expect(sp.containsKey(apk1SettingsPref), isFalse,
        reason: 'the restored value must come from the file');
    await t.runAsync(() => LocalDb.importFromDbFile(path!));
    await sp.reload();
    expect(sp.getBool(apk1SettingsPref), isTrue);
    await apk1Mount(t);
    expect(_tabs, findsNWidgets(5));
    expect(_profile, findsNothing);
    await t.tap(_cog);
    await apk1Settle(t);
    expect(find.byType(MoreSettings), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
