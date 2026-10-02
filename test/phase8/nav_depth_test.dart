// 8A — flatter navigation: from Profile home, Band notifications, Gestures,
// Alarm and every other settings screen are at most two pushes away; Live
// devices is one. Walks the pure views by tapping rows and counts pushes.
// The stateful wrappers' wiring is pinned in nav_depth_guard_test.dart.
// See test/phase8/CONTRACTS.md §8A.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
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
        onAlarm: () => push(const _Dest('Alarm')),
        onBandNotifications: () => push(const _Dest('Band notifications')),
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
        home: ProfileHomeView(
          onSettings: () => push(settings()),
          onLiveDevices: () => push(const _Dest('Live devices')),
          onDevices: () => push(const _Dest('My devices')),
          onEdit: () => push(const _Dest('Edit profile')),
        ),
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

  testWidgets('Live devices is one push from Profile (Quick access)', (t) async {
    await pumpHome(t);
    await walk(t, ['Live devices'], 'Live devices');
    expect(pushes.depth, 1);
  });

  for (final dest in ['Band notifications', 'Gestures', 'Alarm']) {
    testWidgets('$dest is two pushes away, via "The band"', (t) async {
      await pumpHome(t);
      await walk(t, ['More settings', dest], dest);
      expect(pushes.depth, 2);
    });
  }

  for (final (row, dest) in [
    ('Manage notifications', 'Notifications'),
    ('Export, backup, import', 'Data'),
    ('Tasker and Shortcuts', 'Automation'),
    ('Expected sleep schedule', 'Expected sleep schedule'),
  ]) {
    testWidgets('$dest is at most two pushes away', (t) async {
      await pumpHome(t);
      await walk(t, ['More settings', row], dest);
      expect(pushes.depth, lessThanOrEqualTo(2));
    });
  }

  testWidgets('Band notifications row is omitted where the relay cannot run',
      (t) async {
    t.view.physicalSize = const Size(1170, 24000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MoreSettingsView(onGestures: () {}, onAlarm: () {}),
    ));
    await t.pumpAndSettle();
    expect(find.text('Band notifications'), findsNothing);
    expect(find.text('Gestures'), findsOneWidget);
  });
}
