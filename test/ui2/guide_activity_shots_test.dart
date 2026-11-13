// Opt-in review artifacts, not pixel goldens. Run on Boat with GUIDE_SHOTS_DIR
// set to an output directory. No app code or stored wearer data is changed.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_labels.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/bundled_fonts.dart';
import '../support/live_guide_harness.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

final _output = Platform.environment['GUIDE_SHOTS_DIR'];
const _screen = Size(412, 915);
const _dpr = 2.625;

// The Today guide visits DayStrainDetail and ZonesDetail, both Activity
// screens. The remaining Today/Sleep guides never visit Activity screens.
List<Guide> get _guides => [
  for (final entry in kGuideCatalogue)
    if (entry.topic == GuideTopic.activity || entry.guide.id == 'heart-rate-zones') entry.guide,
];

const _labels = <String, List<ScreenLabel>>{
  'heart-rate-zones': [ScreenLabel.homeRingStrain, ScreenLabel.dayStrainHowSet, ScreenLabel.activityZonesSetYourOwnLink],
  'delete-workout': [ScreenLabel.workoutTabHistory, ScreenLabel.workoutDeleteSessionLabel],
  'start-workout': [ScreenLabel.workoutStartSessionLabel, ScreenLabel.activityPickerSearchLabel,
    ScreenLabel.activitySetupStart, ScreenLabel.activityLiveFinishSessionLabel],
  'log-past-workout': [ScreenLabel.workoutTabHistory, ScreenLabel.workoutLogPastFix, ScreenLabel.logWorkoutLogIt],
};

List<double> _rect(Rect r) => [r.left, r.top, r.width, r.height];

Map<String, Object?> _measure(WidgetTester t, LiveGuideOverlayState overlay) {
  final screen = Offset.zero & _screen;
  final shapes = overlay.paintedShapes;
  final counts = {for (final kind in SkeletonKind.values) kind.name: 0};
  var area = 0.0;
  for (final shape in shapes) {
    counts[shape.kind.name] = counts[shape.kind.name]! + 1;
    final clipped = shape.rect.intersect(screen);
    if (!clipped.isEmpty) area += clipped.width * clipped.height;
  }
  final target = overlay.targetRect!;
  final card = t.getRect(find.byKey(GuideStepCard.cardKey));
  final tabs = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TabBar');
  final tabRect = tabs.evaluate().isEmpty ? null : t.getRect(tabs);
  return {
    'shapeCounts': counts,
    'coverageFraction': area / (screen.width * screen.height),
    'targetRect': _rect(target),
    'cardRect': _rect(card),
    'tabBarRect': tabRect == null ? null : _rect(tabRect),
    'cardOverlapsTarget': card.overlaps(target),
    'cardOverlapsTabBar': tabRect != null && card.overlaps(tabRect),
    'shapesOverlappingTabBar': tabRect == null ? 0 : shapes.where((s) => s.rect.overlaps(tabRect)).length,
    'shapes': [for (final s in shapes) {'kind': s.kind.name, 'rect': _rect(s.rect), 'section': s.section}],
  };
}

Future<void> _png(WidgetTester t, RenderRepaintBoundary boundary, String path) async {
  expect(boundary.size, _screen, reason: 'capture the whole phone viewport');
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _dpr);
    try {
      expect(image.width, 1082); // ceil(412 * 2.625)
      expect(image.height, 2402); // ceil(915 * 2.625)
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

// The top page's full-screen repaint boundary excludes the separate live
// overlay entry. Capturing that existing layer preserves scroll, focus, route,
// animation time and session state exactly, without exiting/restarting a run.
RenderRepaintBoundary _plainPage(LiveGuideApp app) {
  RenderObject? object = app.runner.routes.page!.findRenderObject();
  while (object != null) {
    if (object is RenderRepaintBoundary && object.size == _screen) return object;
    object = object.parent;
  }
  throw StateError('The live page has no full-screen repaint boundary');
}

Future<void> _advance(WidgetTester t, LiveGuideApp app, Guide guide, GuideStep step, Rect target) async {
  await t.tapAt(target.center);
  if (guide.id == 'start-workout' && step.id == 'choose-activity') {
    // Search is the guide's target. The guide shield blocks pointer taps on
    // results outside it, so activate the real row callback after searching.
    // Record this driver limitation in the manifest; never silently skip it.
    await t.enterText(find.descendant(of: find.byType(ActivityPicker), matching: find.byType(TextField)), 'Running');
    await settleLiveGuide(t);
    final row = t.widget<ActivityRow>(find.byType(ActivityRow).first);
    row.onTap!();
  }
  await settleLiveGuide(t, frames: 16);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = _output?.isNotEmpty ?? false;
  setUpAll(() async {
    if (!enabled) return;
    await loadFonts(); // Manrope and Barlow Condensed, including bundled weights.
    await skLoadAppFonts(); // Package-scoped Lucide and SDK MaterialIcons too.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'guide_activity_shots_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async { if (enabled) await LocalDb.close(); });

  for (final guide in _guides) {
    // why: the owner needs every live step and its unobscured page to assess
    // what the skeleton hides. A missing/incorrect step fails before capture.
    testWidgets('capture every live Activity step: ${guide.id}', (t) async {
      final l = lookupAppLocalizations(const Locale('en'));
      final records = <Map<String, Object?>>[];
      final directory = p.join(_output!, guide.id);
      final manifest = File(p.join(directory, 'manifest.json'));
      final manifestData = <String, Object?>{
        'guideId': guide.id, 'title': guide.title.of(l), 'locale': 'en',
        'logicalSize': [_screen.width, _screen.height], 'devicePixelRatio': _dpr,
        'coverageDefinition': 'Sum of clipped shape rectangle areas / screen area; overlaps counted repeatedly, not union coverage.',
        'driverNotes': guide.id == 'start-workout'
            ? ['choose-activity: tap search, enter Running, activate the real ActivityRow.onTap callback; live shield blocks result pointer taps.'] : [],
        'steps': records,
      };
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final captureKey = GlobalKey();
        final app = await pumpLiveGuideApp(t, size: _screen, devicePixelRatio: _dpr,
          brightness: brightness, captureKey: captureKey);
        final started = await app.runner.start(guide, band: null);
        expect(started, isA<GuideStarted>());
        final run = (started as GuideStarted).run;
        expect(run.variant.steps, hasLength(_labels[guide.id]!.length));
        for (var i = 0; i < run.variant.steps.length; i++) {
          await settleLiveGuide(t, frames: 18);
          expect(run.state, isA<GuideAtStep>());
          expect((run.state as GuideAtStep).index, i, reason: 'no skipped or off-path steps');
          final step = run.variant.steps[i];
          final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
          expect(overlay.isYielding, isFalse);
          expect(overlay.revealProgress, 1);
          expect(overlay.targetRect, isNotNull);
          expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget);
          expect(t.takeException(), isNull);
          final name = '${(i + 1).toString().padLeft(2, '0')}-${step.id}';
          final dark = brightness == Brightness.dark;
          final guided = dark ? 'dark/$name.png' : '$name.png';
          final measured = _measure(t, overlay);
          await _png(t, t.renderObject<RenderRepaintBoundary>(find.byKey(captureKey)), p.join(directory, guided));
          if (!dark) {
            final plain = '$name-plain.png';
            final page = _plainPage(app);
            expect(identical(page, t.renderObject(find.byKey(captureKey))), isFalse,
              reason: 'plain capture must exclude the root guide overlay');
            await _png(t, page, p.join(directory, plain));
            records.add({
              'id': step.id, 'number': i + 1, 'text': step.caption.of(l).replaceAll('**', ''),
              'targetLabel': _labels[guide.id]![i].of(l),
              'pngPaths': {'guided': guided, 'plain': plain, 'dark': 'dark/$name.png'},
              ...measured,
            });
          } else {
            records[i]['dark'] = measured;
          }
          await t.runAsync(() async {
            await manifest.parent.create(recursive: true);
            await manifest.writeAsString(const JsonEncoder.withIndent('  ').convert(manifestData));
          });
          await _advance(t, app, guide, step, overlay.targetRect!);
          if (i == run.variant.steps.length - 1) {
            expect(run.state, isA<GuideFinished>(), reason: 'last expected target tap completes the run');
          }
        }
        app.runner.exit();
        await t.pumpWidget(const SizedBox());
        await t.pump();
        app.dispose();
        await settleLiveGuide(t, frames: 2);
        expect(t.takeException(), isNull);
      }
    }, skip: !enabled, timeout: const Timeout(Duration(minutes: 8)));
  }
}
