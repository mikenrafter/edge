// Opt-in review artifacts, not pixel goldens. Run on Boat with GUIDE_SHOTS_DIR
// set to an output directory. No app code or stored wearer data is changed.
import '../support/live_guide_focus.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
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

List<Guide> get _guides => [for (final entry in kGuideCatalogue) entry.guide];

const _labels = <String, List<Object>>{
  'heart-rate-zones': [
    ScreenLabel.homeRingStrain,
    ScreenLabel.dayStrainHowSet,
    ScreenLabel.activityZonesSetYourOwnLink,
  ],
  'alarm-schedule': [
    ScreenLabel.settingsAlarmRowTitle,
    'key:alarm-day-enabled',
    'key:alarm-wake-time',
  ],
  'add-nap': [ScreenLabel.sleepDetailEditNaps, ScreenLabel.napsLogANap],
  'remove-detected': [
    ScreenLabel.homeReviewActivities,
    ScreenLabel.dayReviewDiscard,
    ScreenLabel.dayReviewSave,
  ],
  'fix-sleep-times': [
    ScreenLabel.sleepDetailSetTimesMyself,
    ScreenLabel.sleepDetailBackToAutomatic,
  ],
  'delete-workout': [
    ScreenLabel.workoutTabHistory,
    ScreenLabel.workoutDeleteSessionLabel,
  ],
  'start-workout': [
    ScreenLabel.workoutStartSessionLabel,
    ScreenLabel.activityPickerSearchLabel,
    ScreenLabel.activitySetupStart,
    ScreenLabel.activityLiveFinishSessionLabel,
  ],
  'log-past-workout': [
    ScreenLabel.workoutTabHistory,
    ScreenLabel.workoutLogPastFix,
    ScreenLabel.logWorkoutLogIt,
  ],
};

// The shared fixture is read-only. This capture needs the actual sleep edit to
// expose step 2, so reflect the real override row instead of manually jumping
// the guide or changing its variant.
class _ShotsRepo extends GuideFakeRepo {
  final _writes = LocalRepositoryImpl(getProfileMap: () => {});

  @override
  Future<List<SessionSpan>> savedSessionSpans() => _writes.savedSessionSpans();

  @override
  Future<List<ActivitySuggestion>> pendingActivities() =>
      _writes.pendingActivities();

  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async {
    final fixture = await super.getWorkouts(range: range);
    return {
      ...fixture,
      'workouts': [
        for (final row in fixture['workouts'] as List)
          if (await LocalDb.session(row['id'] as String) != null) row,
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async {
    final naps = [
      for (final row in await LocalDb.napEdits(date))
        if (row['source'] == 'manual')
          {
            'start': row['start_ts'],
            'end': row['end_ts'],
            'source': row['source'],
            'duration_min':
                ((row['end_ts'] as int) - (row['start_ts'] as int)) ~/ 60,
          },
    ];
    return {
      'naps': naps,
      'nap_min': naps.fold<int>(
        0,
        (sum, nap) => sum + (nap['duration_min'] as int),
      ),
    };
  }

  @override
  Future<void> deleteWorkout(String id) => _writes.deleteWorkout(id);

  @override
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) =>
      _writes.startWorkout(type, title: title);

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) =>
      _writes.endWorkout(workoutId);

  @override
  Future<Map<String, dynamic>> logManualWorkout({
    required int startTs,
    required int endTs,
    required String type,
    String source = 'manual',
  }) => _writes.logManualWorkout(startTs: startTs, endTs: endTs, type: type, source: source);

  @override
  Future<DayReviewReceipt> saveDayReview({
    required List<ActivityDecision> activities,
    required List<MomentDecision> moments,
    List<ReviewRange> ranges = const [],
    List<MomentWorkoutDecision> workouts = const [],
    Map<AssumedGlass, bool> glasses = const {},
  }) => _writes.saveDayReview(
    activities: activities,
    moments: moments,
    ranges: ranges,
    workouts: workouts,
    glasses: glasses,
  );

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    final night = await super.getDaySleepV2(date);
    final saved = await LocalDb.getSleepOverride(date);
    return saved == null
        ? night
        : {
            ...night,
            'sleep_source': saved['source'],
            'onset_ts': saved['onset_ts'],
            'wake_ts': saved['offset_ts'],
          };
  }

  @override
  Future<Map<String, dynamic>> getDaySleep(String date) => getDaySleepV2(date);
}

Future<void> _resetDb() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  final fixture = GuideFakeRepo();
  final db = await LocalDb.instance;
  for (final suggestion in await fixture.pendingActivities()) {
    await db.insert('activity_suggestions', {
      'id': suggestion.id,
      'kind': suggestion.kind.name,
      'day_id': dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(suggestion.startTs * 1000),
      ),
      'start_ts': suggestion.startTs,
      'end_ts': suggestion.endTs,
      'detection_start': suggestion.startTs,
      'detection_end': suggestion.endTs,
      'details_json': jsonEncode(suggestion.details),
      'created_at': suggestion.startTs,
      'updated_at': suggestion.startTs,
    });
  }
  final workouts = (await fixture.getWorkouts())['workouts'] as List;
  for (final row in workouts) {
    await LocalDb.putSession({
      'id': row['id'],
      'type': row['type'],
      'start_ts': row['start_ts'],
      'end_ts': (row['start_ts'] as int) + (row['duration_min'] as int) * 60,
      'status': 'done',
      'source': 'manual',
      'created_at': (row['start_ts'] as int) * 1000,
    });
  }
}

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
  final tabs = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_TabBar',
  );
  final tabRect = tabs.evaluate().isEmpty ? null : t.getRect(tabs);
  return {
    'shapeCounts': counts,
    'skeletonShapeCount': shapes
        .where((s) => s.kind != SkeletonKind.dim)
        .length,
    'skeletonUnitCount': shapes
        .where((s) => s.kind != SkeletonKind.dim)
        .map((s) => s.section)
        .toSet()
        .length,
    'dimCount': counts['dim'],
    'outlinePresent':
        liveGuideFocus.evaluate().length == 1,
    'coverageFraction': area / (screen.width * screen.height),
    'targetRect': _rect(target),
    'cardRect': _rect(card),
    'tabBarRect': tabRect == null ? null : _rect(tabRect),
    'cardOverlapsTarget': card.overlaps(target),
    'cardOverlapsTabBar': tabRect != null && card.overlaps(tabRect),
    'shapesOverlappingTabBar': tabRect == null
        ? 0
        : shapes.where((s) => s.rect.overlaps(tabRect)).length,
    'shapes': [
      for (final s in shapes)
        {'kind': s.kind.name, 'rect': _rect(s.rect), 'section': s.section},
    ],
  };
}

Future<void> _png(
  WidgetTester t,
  RenderRepaintBoundary boundary,
  String path, {
  double pixelRatio = _dpr,
}) async {
  expect(boundary.size, _screen, reason: 'capture the whole phone viewport');
  await t.runAsync(() async {
    // A post-frame guide plan can dirty component paint during a transition.
    // Flush that paint at the SAME timestamp before reading its boundary.
    t.binding.rootPipelineOwner.flushPaint();
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      expect(image.width, (_screen.width * pixelRatio).ceil());
      expect(image.height, (_screen.height * pixelRatio).ceil());
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
    if (object is RenderRepaintBoundary && object.size == _screen) {
      return object;
    }
    object = object.parent;
  }
  throw StateError('The live page has no full-screen repaint boundary');
}

// Capture real test-time frames rather than manufacturing a slideshow from the
// settled stills. Pointer actions, dialogs and navigation share this clock.
class _PathFrames {
  final WidgetTester tester;
  final GlobalKey captureKey;
  final String directory;
  final bool enabled;
  final records = <Map<String, Object?>>[];
  final actions = <Map<String, Object?>>[];
  int elapsedMs = 0;

  _PathFrames(this.tester, this.captureKey, this.directory, this.enabled);

  Future<void> capture(String phase) async {
    if (!enabled) {
      return;
    }
    final path = 'frames/${records.length.toString().padLeft(5, '0')}.png';
    await _png(
      tester,
      tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey)),
      p.join(directory, path),
      pixelRatio: 1,
    );
    records.add({'path': path, 'timeMs': elapsedMs, 'phase': phase});
  }

  Future<void> frames(String phase, {int count = 18}) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      elapsedMs += 100;
      await capture(phase);
      expect(tester.takeException(), isNull, reason: phase);
    }
  }

  Future<void> tap(Offset point, String action) async {
    actions.add({
      'timeMs': elapsedMs,
      'action': action,
      'point': [point.dx, point.dy],
    });
    await tester.tapAt(point);
    // Do not advance the clock here: the next 100 ms sample includes the route
    // transition's first frame, rather than silently settling past it.
  }

  Future<void> acceptTime(String phase) async {
    expect(find.byType(TimePickerDialog), findsOneWidget, reason: phase);
    final dialog = find.byType(TimePickerDialog);
    final context = tester.element(dialog);
    final ok = find.descendant(
      of: dialog,
      matching: find.text(MaterialLocalizations.of(context).okButtonLabel),
    );
    expect(ok, findsOneWidget);
    await tap(tester.getCenter(ok), phase);
    await frames(phase);
  }
}

Future<void> _plainPng(WidgetTester t, LiveGuideApp app, String path) async {
  final plan = app.runner.dim.looks;
  expect(
    plan,
    isNotNull,
    reason: 'positive control: guided components have a paint plan',
  );
  // No pump: suppress only paint, so the overlay cannot re-publish its plan and
  // neither the clock nor the page's layout/state changes between the pair.
  app.runner.dim.clear();
  try {
    t.binding.rootPipelineOwner.flushPaint();
    await _png(t, _plainPage(app), path);
  } finally {
    app.runner.dim.setLooks(plan);
    t.binding.rootPipelineOwner.flushPaint();
  }
}

Future<void> _advance(
  WidgetTester t,
  LiveGuideApp app,
  Guide guide,
  GuideStep step,
  Rect target,
  _PathFrames path,
) async {
  await path.tap(target.center, '${step.id}: target');
  await path.frames('${step.id}: after target');
  if (guide.id == 'start-workout' && step.id == 'choose-activity') {
    final search = find.descendant(
      of: find.byType(ActivityPicker),
      matching: find.byType(TextField),
    );
    expect(search, findsOneWidget);
    await t.enterText(search, 'Running');
    path.actions.add({
      'timeMs': path.elapsedMs,
      'action': 'enter Running in search',
    });
    await path.frames('choose-activity: search results');
    final row = find.byType(ActivityRow).first;
    expect(
      row,
      findsOneWidget,
      reason: 'real search result before pointer selection',
    );
    await path.tap(t.getRect(row).center, 'choose-activity: Running row');
    await path.frames('choose-activity: navigate to setup');
  }
  if (guide.id == 'fix-sleep-times' && step.id == 'change-times') {
    await path.acceptTime('change-times: accept bed time');
    await path.acceptTime('change-times: accept wake time');
    final nightOnly = find.text('This night only');
    expect(nightOnly, findsOneWidget);
    await path.tap(t.getCenter(nightOnly), 'change-times: this night only');
    await path.frames('change-times: apply');
  }
  if (guide.id == 'add-nap' && step.id == 'log-nap') {
    await path.acceptTime('log-nap: accept fell-asleep time');
    await path.acceptTime('log-nap: accept wake time');
    await path.frames('log-nap: recompute and publish', count: 40);
  }
  if (guide.id == 'alarm-schedule' && step.id == 'set-wake-time') {
    await path.acceptTime('set-wake-time: accept time');
  }
  if (guide.id == 'delete-workout' && step.id == 'delete-session') {
    final remove = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('Remove'),
    );
    expect(remove, findsOneWidget);
    await path.tap(t.getCenter(remove), 'delete-session: confirm removal');
    await path.frames('delete-session: removed');
  }
  if (guide.id == 'fix-sleep-times') {
    // The isolate and SQLite futures use real time, while PublishGate's warm
    // budget uses test time. Record both saves through completion, including
    // Back to automatic, before another theme may reset the database.
    for (
      var i = 0;
      i < 500 && (app.state.reanalyzing || app.state.sleepOperations.busy);
      i++
    ) {
      await path.frames('${step.id}: waiting for recompute/publish', count: 1);
    }
    expect(
      app.state.sleepOperations.busy,
      isFalse,
      reason: '${step.id} sleep operation completed',
    );
    expect(
      app.state.reanalyzing,
      isFalse,
      reason: '${step.id} worker completed before DB reset',
    );
    await path.frames('${step.id}: saved state', count: 4);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = _output?.isNotEmpty ?? false;
  setUpAll(() async {
    if (!enabled) return;
    expect(
      _guides.map((g) => g.id),
      unorderedEquals(_labels.keys),
      reason: 'all eight review paths must match the shipped catalogue',
    );
    await loadFonts(); // Manrope and Barlow Condensed, including bundled weights.
    await skLoadAppFonts(); // Package-scoped Lucide and SDK MaterialIcons too.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'guide_activity_shots_test.db';
    await _resetDb();
  });
  tearDownAll(() async {
    if (enabled) await LocalDb.close();
  });

  for (final guide in _guides) {
    // why: the owner needs every live step and its unobscured page to assess
    // what the skeleton hides. A missing/incorrect step fails before capture.
    // proves: CLAIM(overlay-pass-through), CLAIM(overlay-reveal).
    testWidgets(
      'capture every live catalogue step: ${guide.id}',
      (t) async {
        final l = lookupAppLocalizations(const Locale('en'));
        final records = <Map<String, Object?>>[];
        final directory = p.join(_output!, guide.id);
        final manifest = File(p.join(directory, 'manifest.json'));
        await t.runAsync(() async {
          final old = Directory(directory);
          if (await old.exists()) await old.delete(recursive: true);
        });
        final manifestData = <String, Object?>{
          'guideId': guide.id,
          'title': guide.title.of(l),
          'locale': 'en',
          'logicalSize': [_screen.width, _screen.height],
          'devicePixelRatio': _dpr,
          'coverageDefinition':
              'Sum of clipped shape rectangle areas / screen area; overlaps counted repeatedly, not union coverage.',
          'driverNotes': [
            'Every advance uses real pointer taps; search text uses enterText.',
            'Sleep fixture reads the real override row after the time-picker save.',
            'Plain capture clears/restores the in-tree paint plan without pumping time.',
            'Display metrics are fixtures; pending activities, saved nap edits, sleep overrides and workout deletion reflect the isolated test database.',
          ],
          'steps': records,
        };
        for (final brightness in [Brightness.light, Brightness.dark]) {
          await t.runAsync(_resetDb);
          final captureKey = GlobalKey();
          final app = await pumpLiveGuideApp(
            t,
            size: _screen,
            devicePixelRatio: _dpr,
            brightness: brightness,
            captureKey: captureKey,
            repo: _ShotsRepo(),
          );
          final dark = brightness == Brightness.dark;
          final path = _PathFrames(t, captureKey, directory, !dark);
          if (!dark) {
            manifestData['sequence'] = {
              'frameIntervalMs': 100,
              'frameSize': [412, 915],
              'gifPath': '../gifs/${guide.id}.gif',
              'frames': path.records,
              'actions': path.actions,
            };
          }
          final started = await app.runner.start(guide, band: null);
          expect(started, isA<GuideStarted>());
          final run = (started as GuideStarted).run;
          expect(run.variant.steps, hasLength(_labels[guide.id]!.length));
          for (var i = 0; i < run.variant.steps.length; i++) {
            await path.frames('${run.variant.steps[i].id}: reveal');
            expect(run.state, isA<GuideAtStep>());
            expect(
              (run.state as GuideAtStep).index,
              i,
              reason: 'no skipped or off-path steps',
            );
            final step = run.variant.steps[i];
            final overlay = t.state<LiveGuideOverlayState>(
              find.byType(LiveGuideOverlay),
            );
            expect(overlay.isYielding, isFalse);
            expect(overlay.revealProgress, 1);
            expect(overlay.targetRect, isNotNull);
            expect(liveGuideFocus, findsOneWidget);
            expect(t.takeException(), isNull);
            final name = '${(i + 1).toString().padLeft(2, '0')}-${step.id}';
            final guided = dark ? 'dark/$name.png' : '$name.png';
            final measured = _measure(t, overlay);
            await _png(
              t,
              t.renderObject<RenderRepaintBoundary>(find.byKey(captureKey)),
              p.join(directory, guided),
            );
            if (!dark) {
              final plain = '$name-plain.png';
              final page = _plainPage(app);
              expect(
                identical(page, t.renderObject(find.byKey(captureKey))),
                isFalse,
                reason: 'plain capture must exclude the root guide overlay',
              );
              await _plainPng(t, app, p.join(directory, plain));
              records.add({
                'id': step.id,
                'number': i + 1,
                'text': step.caption.of(l).replaceAll('**', ''),
                'targetLabel': switch (_labels[guide.id]![i]) {
                  final ScreenLabel label => label.of(l),
                  final Object key => key.toString(),
                },
                'pngPaths': {
                  'guided': guided,
                  'plain': plain,
                  'dark': 'dark/$name.png',
                },
                ...measured,
              });
            } else {
              records[i]['dark'] = measured;
            }
            await t.runAsync(() async {
              await manifest.parent.create(recursive: true);
              await manifest.writeAsString(
                const JsonEncoder.withIndent('  ').convert(manifestData),
              );
            });
            await _advance(t, app, guide, step, overlay.targetRect!, path);
            if (i == run.variant.steps.length - 1) {
              expect(
                run.state,
                isA<GuideFinished>(),
                reason: 'last expected target tap completes the run',
              );
            }
          }
          await t.runAsync(
            () => manifest.writeAsString(
              const JsonEncoder.withIndent('  ').convert(manifestData),
            ),
          );
          app.runner.exit();
          await t.pumpWidget(const SizedBox());
          await t.pump();
          app.dispose();
          // A publish already in its warm timeout may finish after disposal.
          await settleLiveGuide(t, frames: 30);
          expect(t.takeException(), isNull);
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 12)),
    );
  }
}
