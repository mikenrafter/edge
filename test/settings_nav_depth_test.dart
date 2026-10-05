// 8A — flatter navigation: from the Settings landing, App notifications on the
// band, Gestures, Alarm and every other settings screen are at most two pushes
// away. 8AE moved Live devices (now Developer), Edit profile, AI coach and the
// rest of Profile's old rows into Settings. 8AF.7 removed the Profile landing
// screen, so Settings is the start and each of them is ONE push. Walks the
// pure views by tapping rows and counts pushes.
// The stateful wrappers' wiring is pinned in nav_depth_guard_test.dart.
// See test/phase8/CONTRACTS.md §8A.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

class _Pushes extends NavigatorObserver {
  int depth = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) depth++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => depth--;
}

class _Dest extends StatelessWidget {
  const _Dest(this.name);
  final String name;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('DEST:$name')));
}

void main() {
  late GlobalKey<NavigatorState> nav;
  late _Pushes pushes;

  void push(Widget w) =>
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => w));

  Widget settings() => MoreSettingsView(
        relaySupported: true,
        devMode: true,
        onAlarm: () => push(const _Dest('Alarm')),
        onBandNotifications: () =>
            push(const _Dest('App notifications on the band')),
        onDevices: () => push(const _Dest('My devices')),
        onHaptics: () => push(const _Dest('Haptics')),
        onEditProfile: () => push(const _Dest('Edit profile')),
        onCoach: () => push(const _Dest('AI coach')),
        onLiveDevices: () => push(const _Dest('Live devices')),
        onDeviceLab: () => push(const _Dest('Device lab')),
        onGestures: () => push(const _Dest('Gestures')),
        onNotifications: () => push(const _Dest('Notifications')),
        onData: () => push(const _Dest('Data')),
        onAutomation: () => push(const _Dest('Automation')),
        onEditSleepSchedule: () => push(const _Dest('Expected sleep schedule')),
      );

  Future<void> pumpHome(WidgetTester t) async {
    nav = GlobalKey<NavigatorState>();
    pushes = _Pushes();
    t.view.physicalSize = const Size(1170, 24000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
      value: LocaleController.seed(null),
      child: MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [pushes],
        theme: buildTheme(Brightness.light),
        home: settings(),
      ),
    ));
    await t.pumpAndSettle();
  }

  Future<void> walk(WidgetTester t, List<String> rows, String dest) async {
    for (final r in rows) {
      final f = find.text(r);
      expect(f, findsWidgets, reason: 'row "$r" on the way to $dest');
      await t.tap(f.last);
      await t.pumpAndSettle();
    }
    expect(find.text('DEST:$dest'), findsOneWidget);
  }

  testWidgets('My devices is one push from Settings (Band)', (t) async {
    await pumpHome(t);
    await walk(t, ['My devices'], 'My devices');
    expect(pushes.depth, 1);
  });

  for (final dest in [
    'App notifications on the band',
    'Gestures',
    'Alarm',
    'Haptics',
  ]) {
    testWidgets('$dest is one push from Settings, via "Band" or "Alerts"',
        (t) async {
      await pumpHome(t);
      await walk(t, [dest], dest);
      expect(pushes.depth, 1);
    });
  }

  for (final (row, dest) in [
    ('Alerts and notifications', 'Notifications'),
    ('Export, backup, import', 'Data'),
    ('Tasker and Shortcuts', 'Automation'),
    ('Expected sleep schedule', 'Expected sleep schedule'),
    ('Edit profile', 'Edit profile'),
    ('AI coach', 'AI coach'),
    ('Live devices', 'Live devices'),
    ('Device lab', 'Device lab'),
  ]) {
    testWidgets('$dest is one push from Settings', (t) async {
      await pumpHome(t);
      await walk(t, [row], dest);
      expect(pushes.depth, 1);
    });
  }

  testWidgets(
      'App notifications on the band row is omitted where the relay cannot run',
      (t) async {
    t.view.physicalSize = const Size(1170, 24000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    // The Language row (moved in from Profile, 8AE) reads the locale.
    await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
      value: LocaleController.seed(null),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MoreSettingsView(onGestures: () {}, onAlarm: () {}),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('App notifications on the band'), findsNothing);
    expect(find.text('Gestures'), findsOneWidget);
  });
}
