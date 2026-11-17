// Cross-screen regressions found in the first fork Help review.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide_navigation.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/help_screen.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show SubTabs;
import '../support/guide_r2_scenes.dart' show r2OpenDb, r2Tab, r2Guide;
import '../support/live_guide_harness.dart';
import '../support/bundled_fonts.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

Future<void> _footer(WidgetTester t) async {
  final button = find.widgetWithText(TextButton, 'Looking for something?');
  for (var i = 0; i < 45 && button.hitTestable().evaluate().isEmpty; i++) {
    await t.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await settleLiveGuide(t, frames: 4);
  }
  expect(button.hitTestable(), findsOneWidget);
  await t.tap(button);
  await settleLiveGuide(t);
}

void main() {
  setUpAll(() async {
    await r2OpenDb('help_review_flow.db');
    if (Platform.environment['HELP_REVIEW_SHOTS'] != null) {
      await loadFonts();
      await skLoadAppFonts();
    }
  });
  tearDownAll(LocalDb.close);
  // WHY: translated directions must agree with the verified fork controls and
  // nap union policy. This fixture is reviewed copy, independent of production.
  // catches: restoring the inherited bottom/overlap prohibition or omitting Save.
  test('reviewed guide copy in all seven locales', () {
    final expected = jsonDecode(File('test/fixtures/help_review_copy.json').readAsStringSync()) as Map<String, dynamic>;
    expect(expected.keys.toSet(), {'en', 'de', 'es', 'fr', 'hi', 'ru', 'zh'},
        reason: 'all seven reviewed fork translations stay covered; Thai was added by main');
    for (final locale in AppLocalizations.supportedLocales.where(
        (locale) => expected.containsKey(locale.languageCode))) {
      final arb = jsonDecode(File('lib/l10n/app_${locale.languageCode}.arb').readAsStringSync()) as Map<String, dynamic>;
      for (final entry in (expected[locale.languageCode] as Map<String, dynamic>).entries) {
        expect(arb[entry.key], entry.value, reason: '${locale.languageCode}: ${entry.key}');
      }
    }
  });

  for (final start in [GuideNode.activityHistory, GuideNode.activityActivities]) {
    for (final guide in ['start-workout', 'log-past-workout']) {
      // WHY: CLAIM(help-start-on-path). A footer can be opened from a retained
      // sub-tab; valid later steps stay in place, other starts reach step one.
      // catches: retaining History for start-workout, or always resetting History.
      testWidgets('${start.name} footer starts $guide on a valid step', (t) async {
        final app = await pumpLiveGuideApp(t);
        await t.tap(r2Tab(2));
        await settleLiveGuide(t, frames: 16);
        final l = lookupAppLocalizations(const Locale('en'));
        final label = start == GuideNode.activityHistory ? l.workoutTabHistory : l.workoutTabActivities;
        final tab = find.descendant(of: find.byType(SubTabs), matching: find.text(label));
        await t.ensureVisible(tab);
        await settleLiveGuide(t);
        await t.tap(tab.hitTestable());
        await settleLiveGuide(t);
        expect(GuideNavigation.location(app.runner.routes.page!), start, reason: 'prove the starting sub-tab');
        if (start == GuideNode.activityHistory) {
          final action = find.text(l.workoutLogPastFix);
          await t.ensureVisible(action);
          await settleLiveGuide(t);
          final sessions = find.byKey(const ValueKey('list:sessions'));
          expect(sessions, findsOneWidget);
          expect(t.getRect(action).bottom, lessThan(t.getRect(sessions).top), reason: 'the real action is above sessions, including a populated list');
        }
        await _footer(t);
        await t.tap(find.byKey(HelpScreen.guideRowKey(guide)));
        await settleLiveGuide(t, frames: 40);
        final run = app.runner.activeRun!;
        expect(run.state, isA<GuideAtStep>());
        final inPlace = start == GuideNode.activityHistory && guide == 'log-past-workout';
        expect(run.currentStep!.id, inPlace ? 'log-past' : guide == 'start-workout' ? 'start-card' : 'open-history');
        expect(GuideNavigation.location(app.runner.routes.page!), inPlace ? GuideNode.activityHistory : GuideNode.activityOverview);
        expect(t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)).targetRect, isNotNull);
        app.runner.exit();
        await t.pumpWidget(const SizedBox());
        await t.pump();
      });
    }
  }

  // WHY: CLAIM(help-start-in-place). A matching pushed page may have a dirty
  // draft. Starting its guide must retain that page, not invoke its leave guard.
  // catches: always popping to the shell even when a later guide step matches.
  testWidgets('Help retains a matching pushed alarm page and its draft', (t) async {
    final app = await pumpLiveGuideApp(t);
    app.navigator.push(MaterialPageRoute<void>(builder: (_) => const AlarmScreen()));
    await settleLiveGuide(t, frames: 30);
    await t.tap(find.byKey(const ValueKey('alarm-day-enabled')));
    await settleLiveGuide(t);
    final page = find.byType(AlarmScreenView).evaluate().single;
    expect(find.textContaining('Unsaved changes.'), findsOneWidget);
    app.navigator.push(MaterialPageRoute<void>(builder: (_) => const HelpScreen()));
    await settleLiveGuide(t);
    await t.ensureVisible(find.byKey(HelpScreen.guideRowKey('alarm-schedule')));
    await t.tap(find.byKey(HelpScreen.guideRowKey('alarm-schedule')).hitTestable());
    await settleLiveGuide(t, frames: 35);
    expect(app.runner.activeRun?.currentStep?.id, 'set-wake-time');
    expect(find.byType(AlarmScreenView).evaluate().single, same(page));
    expect(find.byType(AlertDialog), findsNothing, reason: 'starting in place must not ask to discard the draft');
    expect(find.textContaining('Unsaved changes.'), findsOneWidget);
    app.runner.exit();
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });

  // WHY: CLAIM(alarm-guide-save). A picker only changes a draft; the final
  // instruction must expose Save and use the production AlarmScreen/AppState/DB.
  // catches: Wake time as final target, Save as always-present anchor, blocked
  // Wake time input, or a Save target that only finishes without persisting.
  testWidgets('alarm picker leaves the guide unfinished, Save persists chosen time', (t) async {
    final captureKey = GlobalKey();
    final app = await pumpLiveGuideApp(t, size: const Size(412, 915), brightness: Brightness.dark, captureKey: captureKey);
    await app.runner.start(r2Guide('alarm-schedule'), band: null);
    await settleLiveGuide(t, frames: 40);
    var overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(app.runner.activeRun!.currentStep!.id, 'open-alarm');
    await t.tapAt(overlay.targetRect!.center);
    await settleLiveGuide(t, frames: 40);
    expect(app.runner.activeRun!.currentStep!.id, 'pick-day', reason: 'Save must not skip the day selection');
    final selectedDay = t.widget<SubTabs>(find.byType(SubTabs)).index;
    await t.tap(find.byKey(const ValueKey('alarm-day-enabled')));
    await settleLiveGuide(t, frames: 40);
    expect(app.runner.activeRun!.currentStep!.id, 'set-wake-time');
    final before = await t.runAsync(LocalDb.alarmScheduleRows);
    await t.ensureVisible(find.byKey(const ValueKey('alarm-wake-time')));
    await settleLiveGuide(t);
    await t.tap(find.byKey(const ValueKey('alarm-wake-time')).hitTestable());
    await settleLiveGuide(t);
    expect(find.byType(TimePickerDialog), findsOneWidget);
    final material = MaterialLocalizations.of(t.element(find.byType(TimePickerDialog)));
    await t.tap(find.byTooltip(material.inputTimeModeButtonLabel));
    await settleLiveGuide(t);
    final inputs = find.descendant(of: find.byType(TimePickerDialog), matching: find.byType(TextField));
    await t.enterText(inputs.at(0), '9');
    await t.enterText(inputs.at(1), '17');
    await t.tap(find.text(material.okButtonLabel));
    await settleLiveGuide(t, frames: 30);
    expect(app.runner.activeRun!.state, isA<GuideAtStep>());
    expect(await t.runAsync(LocalDb.alarmScheduleRows), before, reason: 'picker edits remain a draft');
    await t.ensureVisible(find.text('Save'));
    await settleLiveGuide(t);
    overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.targetRect!.overlaps(t.getRect(find.text('Save'))), isTrue);
    final shots = Platform.environment['HELP_REVIEW_SHOTS'];
    if (shots != null) {
      final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      await t.runAsync(() async {
        t.binding.rootPipelineOwner.flushPaint();
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$shots/alarm-save-after-picker.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }
    await t.tapAt(overlay.targetRect!.center);
    await settleLiveGuide(t, frames: 40);
    expect(app.runner.activeRun!.state, isA<GuideFinished>());
    final saved = (await t.runAsync(LocalDb.alarmScheduleRows))!.singleWhere((e) => e['weekday'] == selectedDay);
    expect(saved['hour'], 9);
    expect(saved['minute'], 17);
    expect(saved['enabled'], 1);
    app.runner.exit();
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
}
