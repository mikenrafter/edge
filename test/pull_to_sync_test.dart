import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/state/app_state.dart' show SyncPresentationState, SyncStep, SyncStepId, SyncStepStatus;
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/pull_to_sync.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/bundled_fonts.dart';
import 'support/header_rows_fakes.dart';
import 'support/home_header_pilot_fakes.dart';
import 'support/pilot_shots.dart';
import 'support/tabs_consistency_fakes.dart';

const _pill = ValueKey('home-header-pill');
final _circle = find.byIcon(LucideIcons.rotateCcw);

class _App extends PilotHeaderApp {
  _App() : super(pres: _idle, battery: 49) {
    repo = _Repo();
  }

  static final _idle = pilotIdle(lastSync: DateTime(2026, 11, 19, 2, 18));

  int refreshes = 0;

  @override
  Future<void> refreshData() async {
    refreshes++;
    setPres(SyncPresentationState(
      phase: 'connecting',
      busy: true,
      startedAt: pilotNow,
      lastSuccess: _idle.lastSuccess,
      steps: [SyncStep(id: SyncStepId.connect, status: SyncStepStatus.running, startedAt: pilotNow)],
    ));
  }
}

class _Repo extends EmptyTabsRepo {
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async => DateTime(2026, 11, 19, 2, 15);
}

Future<void> _tab(WidgetTester t, _App app, ShellDomain tab) async {
  pilotSurface(t);
  await pilotPrefs();
  // The retired preference must not suppress the gesture after upgrades.
  await (await SharedPreferences.getInstance()).setBool('pull_to_sync', false);
  await Prefs.reload();
  await t.pumpWidget(pilotApp(app, Scaffold(body: pilotShot(pilotTab(tab)))));
  await t.pump();
  await t.pump(const Duration(milliseconds: 250));
  expect(find.byType(PullToSync), findsOneWidget);
  expect(find.byKey(_pill), findsOneWidget);
}

Future<TestGesture> _begin(WidgetTester t) async {
  final gesture = await t.startGesture(const Offset(180, 130));
  await gesture.moveBy(const Offset(0, 25));
  await t.pump();
  return gesture;
}

Future<void> _move(WidgetTester t, TestGesture gesture, double offset) async {
  await gesture.moveBy(Offset(0, offset));
  await t.pump(const Duration(milliseconds: 30));
}

Opacity _opacity(WidgetTester t) =>
    t.widget<Opacity>(find.ancestor(of: _circle, matching: find.byType(Opacity)).first);
Transform _rotation(WidgetTester t) =>
    t.widget<Transform>(find.ancestor(of: _circle, matching: find.byType(Transform)).first);

void main() {
  final ticks = <String>[];

  setUpAll(loadFonts);
  setUp(() {
    h24();
    ticks.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') ticks.add(call.arguments as String);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // why: a single drag can cross the threshold in both directions. Lifting
  // below it starts one sync and lifting above it must leave the tab alone.
  testWidgets('page, rotation, colour, haptics and release follow the drag', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await withClock(Clock.fixed(pilotNow), () async {
      await _tab(t, app, ShellDomain.today);
      final start = t.getTopLeft(find.byKey(_pill)).dy;
      double pageOffset() => t.getTopLeft(find.byKey(_pill)).dy - start;
      final palette = P.of(t.element(find.byType(PullToSync)));

      final pull = await _begin(t);
      await _move(t, pull, 24);
      final first = pageOffset();
      final firstOpacity = _opacity(t).opacity;
      final firstRotation = _rotation(t).transform;
      expect(first, greaterThan(10));
      expect(firstOpacity, inExclusiveRange(0, 1));
      expect(firstOpacity, closeTo(first / 72, .01));
      expect(firstRotation.entry(0, 0), closeTo(math.cos(firstOpacity * 2 * math.pi), .01));
      expect(t.getRect(_circle).bottom, lessThanOrEqualTo(t.getRect(find.byKey(_pill)).top));
      expect(t.widget<Icon>(_circle).color, palette.ink2);
      expect(ticks, isEmpty);
      await takePilotShot(t, 'pull-1-build');

      await _move(t, pull, 45);
      expect(pageOffset(), greaterThan(first));
      expect(_opacity(t).opacity, greaterThan(firstOpacity));
      expect(_rotation(t).transform, isNot(firstRotation));
      expect(ticks, isEmpty);
      await takePilotShot(t, 'pull-2-build');

      await _move(t, pull, 120);
      expect(_opacity(t).opacity, 1);
      expect(t.widget<Icon>(_circle).color, palette.on(C.green));
      expect(ticks, ['HapticFeedbackType.selectionClick']);
      expect(app.refreshes, 0);
      await takePilotShot(t, 'pull-3-build');

      await pull.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 80));
      await t.pump();
      expect(app.refreshes, 1);
      expect(t.widget<Icon>(_circle).color, palette.on(C.green));
      await takePilotShot(t, 'pull-4-build');
      await t.pumpAndSettle();
      expect(pageOffset(), closeTo(0, .1));
      expect(_circle, findsNothing);
      expect(ticks, hasLength(1));

      app.setPres(_App._idle);
      await t.pump();
      final cancel = await _begin(t);
      await _move(t, cancel, 200);
      expect(ticks, hasLength(2));
      await _move(t, cancel, -265);
      expect(ticks, hasLength(3));
      expect(t.widget<Icon>(_circle).color, palette.ink2);
      await cancel.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 80));
      await t.pump();
      expect(_opacity(t).opacity, inExclusiveRange(0, 1));
      await takePilotShot(t, 'pull-4b-build');
      await t.pumpAndSettle();
      expect(app.refreshes, 1);
      expect(ticks, hasLength(3));
      expect(find.byType(BottomSheet), findsNothing);
      expect(_circle, findsNothing);
    });
  });

  for (final tab in [ShellDomain.sleep, ShellDomain.activity]) {
    // why: the shipped Sleep and Activity roots must take the same sync path as Today.
    testWidgets('${tab.label} moves its header and starts the shared sync', (t) async {
      final app = _App();
      addTearDown(app.dispose);
      await withClock(Clock.fixed(pilotNow), () async {
        await _tab(t, app, tab);
        final header = find.byKey(_pill);
        final start = t.getTopLeft(header).dy;
        final pull = await _begin(t);
        await _move(t, pull, 180);
        expect(t.getTopLeft(header).dy - start, greaterThanOrEqualTo(72));
        await pull.up();
        await t.pumpAndSettle();
        expect(app.refreshes, 1);
        expect(t.getTopLeft(header).dy, closeTo(start, .1));
      });
    });
  }

  // why: letting go mid-sync should surface progress without starting another sync.
  testWidgets('releasing past the line during a sync opens details', (t) async {
    final app = _App()..setPres(pilotSync('downloading'));
    addTearDown(app.dispose);
    await withClock(Clock.fixed(pilotNow), () async {
      await _tab(t, app, ShellDomain.today);
      final pull = await _begin(t);
      await _move(t, pull, 180);
      await pull.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 450));
      await t.pump();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(app.refreshes, 0);
      await t.pumpWidget(const SizedBox());
    });
  });
}
