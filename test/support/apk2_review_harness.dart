// SQLite setup follows activity_review_test; route/provider setup follows
// detected_activities_ui_test. Reuse settle, captureFlutterErrors and the local
// clock fixture used by the existing moment-review tests. No production writer
// is mocked. Only timeline reads and the proposal query's clock are fixed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'apk2_keys.dart';
import 'as_of_recalc_fakes.dart' show settle;
import 'moment_review_fakes.dart' show reviewNow;

const apk2Day = '2026-10-06';
const apk2NewerDay = '2026-10-07';
const apk2NapA = 'activity:apk2-nap-a';
const apk2NapB = 'activity:apk2-nap-b';
const apk2WorkoutA = 'activity:apk2-workout-a';
const apk2WorkoutB = 'activity:apk2-workout-b';
const apk2MarkA = 'moment:2026-10-06 09:15';
const apk2MarkB = 'moment:2026-10-06 10:05';
const apk2Meal = 'moment:2026-10-06 08:10';
const apk2Answered = 'moment:2026-10-06 20:45';
const apk2AnswerNote = 'Knees sore after the stairs; settled after resting.';
const apk2ActivityIds = {apk2NapA, apk2NapB, apk2WorkoutA, apk2WorkoutB};
const apk2MixedIds = {...apk2ActivityIds, apk2MarkA, apk2MarkB};

int apk2At(int hour, [int minute = 0]) =>
    DateTime(2026, 10, 6, hour, minute).millisecondsSinceEpoch ~/ 1000;

Finder apk2Key(String key) => find.byKey(ValueKey<String>(key));
Finder apk2Item(String id) => apk2Key('$apk2TrayItemPrefix$id');
Finder apk2Row(String id) => apk2Key('$apk2RowPrefix$id');
Finder apk2Keep(String id) => apk2Key('$apk2KeepPrefix$id');
Finder apk2Discard(String id) => apk2Key('$apk2DiscardPrefix$id');

/// Asserts before interacting, so today's missing controls fail an expectation,
/// rather than throwing from tap(), widget(), getRect() or getSemantics().
Future<void> apk2Tap(WidgetTester t, Finder f) async {
  expect(f, findsOneWidget);
  await t.ensureVisible(f);
  await t.tap(f);
  // Reuse the suite's SQLite-aware settle; it also advances route transitions.
  // Do not pumpAndSettle here: the loading-state test deliberately holds a read.
  await settle(t);
}

bool apk2Enabled(WidgetTester t, Finder f) {
  expect(f, findsOneWidget);
  final data = t.getSemantics(f).getSemanticsData();
  expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
  expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
  return data.hasFlag(SemanticsFlag.isEnabled);
}

bool apk2Selected(WidgetTester t, Finder f) {
  expect(f, findsOneWidget);
  return t.getSemantics(f).getSemanticsData().hasFlag(SemanticsFlag.isSelected);
}

Set<String> apk2PageIds() => {
  for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(apk2TrayItemPrefix)).evaluate())
    ((e.widget.key! as ValueKey<String>).value).substring(apk2TrayItemPrefix.length),
};

/// Navigate at most two pages. Failure is an assertion naming the missing item.
Future<void> apk2Show(WidgetTester t, String id) async {
  expect(apk2Key(apk2Tray), findsOneWidget);
  if (apk2Item(id).evaluate().isEmpty) {
    final next = apk2Key(apk2Next);
    if (apk2Enabled(t, next)) {
      await apk2Tap(t, next);
    } else {
      await apk2Tap(t, apk2Key(apk2Previous));
    }
  }
  expect(apk2Item(id), findsOneWidget, reason: '$id must be in this day queue');
}

/// Count occurrences across the actual semantics tree, including merged labels.
/// Finder counts alone can miss a status repeated twice in one merged sentence.
int apk2SpokenCount(WidgetTester t, String phrase) {
  final root = t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
  var count = 0;
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    count += RegExp(RegExp.escape(phrase)).allMatches(
        '${data.label}\n${data.value}\n${data.hint}').length;
    node.visitChildren((child) { visit(child); return true; });
  }
  visit(root);
  return count;
}

/// Status keys may wrap Text or a status card. Check each visible sentence,
/// so a duplicated merged announcement fails as well as duplicate nodes.
void apk2StatusSpokenOnce(WidgetTester t, String key) {
  final status = apk2Key(key);
  expect(status, findsOneWidget);
  final sentences = t.widgetList<Text>(find.descendant(of: status,
      matchRoot: true, matching: find.byType(Text)))
      .map((w) => w.data ?? w.textSpan!.toPlainText())
      .where((s) => s.trim().isNotEmpty).toList();
  expect(sentences, isNotEmpty, reason: 'the status must also be visible');
  for (final sentence in sentences) {
    expect(apk2SpokenCount(t, sentence), 1, reason: sentence);
  }
}

class Apk2Repository extends LocalRepositoryImpl {
  Apk2Repository(this.store) : super(getProfileMap: () => {});
  final ActivityStore store;
  bool failQueueRead = false;
  Completer<List<ActivitySuggestion>>? queueGate;

  @override
  Future<List<ActivitySuggestion>> pendingActivities() async {
    if (queueGate != null) return queueGate!.future;
    if (failQueueRead) throw StateError('APK2 queue read failed');
    // ActivityStore's default uses DateTime.now; explicitly supply the fixture
    // instant so this queue does not expire as the test suite gets older.
    return store.pending(nowTs: reviewNow.millisecondsSinceEpoch ~/ 1000);
  }
  @override
  Future<int> pendingActivityCount() async => (await pendingActivities()).length;
  @override
  Future<List<String>> availableDays() async => [apk2NewerDay, apk2Day];
  @override
  Future<Map<String, dynamic>> getTodayStored() async =>
      {'status': {'today_day': apk2NewerDay}};
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => {
    'date': date,
    'day_start': DateTime.parse(date).millisecondsSinceEpoch ~/ 1000,
    'day_end': DateTime(2026, 10, date == apk2Day ? 7 : 8)
        .millisecondsSinceEpoch ~/ 1000,
    'hr': [
      for (var h = 0; h < 24; h++)
        {'t': DateTime(2026, 10, date == apk2Day ? 6 : 7, h)
            .millisecondsSinceEpoch ~/ 1000, 'v': 60 + h % 5},
    ],
    // Six distinct factual rows, plus two answered moments below = eight.
    // Different event ids avoid the repeated-event collapsing policy.
    'events': date == apk2Day ? [
      {'event_id': 7, 'ts': apk2At(1)},
      {'event_id': 8, 'ts': apk2At(2)},
      {'event_id': 15, 'ts': apk2At(4)},
      {'event_id': 21, 'ts': apk2At(5)},
      {'event_id': 22, 'ts': apk2At(6)},
      {'event_id': 57, 'ts': apk2At(7)},
    ] : [],
  };
  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => {};
  @override
  Future<List<Map<String, Object?>>> getDayObservations(String date) async => [];
}

class Apk2Rig {
  Apk2Rig._(this.db, this.store, this.repo, this.app);
  final Database db;
  final ActivityStore store;
  final Apk2Repository repo;
  final AppState app;
  final navigator = GlobalKey<NavigatorState>();

  static Future<Apk2Rig> create(WidgetTester t, {bool pending = true}) async {
    SharedPreferences.setMockInitialValues({'notify_auto_detect': false});
    await Prefs.ensureLoaded();
    await Prefs.setStringAcked(MomentReviewStore.prefKey, '');
    ClockFormatController.seed(ClockFormat.h24);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final oldName = LocalDb.dbName;
    late Directory dir;
    late Database db;
    await t.runAsync(() async {
      await LocalDb.close();
      dir = await Directory.systemTemp.createTemp('apk2-review-');
      LocalDb.dbName = '${dir.path}/review.db';
      db = await LocalDb.instance;
      await db.update('activity_review_meta', {
        'activated_at': apk2At(0) - 1, 'legacy_migrated': 1,
      });
      await LocalDb.putJournal(apk2Day,
          jsonEncode(['moment 09:15', 'moment 10:05',
            'moment 08:10', 'moment 20:45']), 'A long walk by the river.');
      for (final label in [
        MomentLabel(date: apk2Day, hhmm: '08:10', label: 'meal',
            note: 'Lunch packed for the trail.', answeredAtMs: 1),
        MomentLabel(date: apk2Day, hhmm: '20:45', label: 'other',
            note: apk2AnswerNote, answeredAtMs: 1),
      ]) {
        await LocalDb.putMomentLabel(label);
      }
      if (!pending) {
        // No pending means no pending marks either, independent of whether a
        // future breakdown offers marks when the follow-up setting is off.
        for (final hhmm in ['09:15', '10:05']) {
          await LocalDb.putMomentLabel(MomentLabel(
              date: apk2Day, hhmm: hhmm, answeredAtMs: 1));
        }
      }
    });
    final store = ActivityStore(db);
    if (pending) {
      await t.runAsync(() async {
        await store.reconcile(ActivityKind.nap, [
          {'id': 'apk2-nap-a', 'start': apk2At(11), 'end': apk2At(11, 25)},
          {'id': 'apk2-nap-b', 'start': apk2At(15), 'end': apk2At(15, 20)},
        ]);
        await store.reconcile(ActivityKind.workout, [
          {'id': 'apk2-workout-a', 'start_ts': apk2At(12),
            'end_ts': apk2At(12, 30), 'sport': 'walking'},
          {'id': 'apk2-workout-b', 'start_ts': apk2At(18),
            'end_ts': apk2At(18, 40), 'sport': 'running'},
        ]);
      });
    }
    final repo = Apk2Repository(store);
    final app = AppState.forTesting()..repo = repo;
    final rig = Apk2Rig._(db, store, repo, app);
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.runAsync(() async {
        await LocalDb.close();
        LocalDb.dbName = oldName;
        await dir.delete(recursive: true);
      });
    });
    return rig;
  }

  Future<void> mount(WidgetTester t, {Widget? entry, bool marked = false,
      double scale = 1, MomentReviewService? service}) async {
    t.view.physicalSize = const Size(1080, 2700); // 360 x 900 logical points.
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
    addTearDown(theme.dispose);
    final momentService = service ?? MomentReviewService();
    if (service == null) addTearDown(momentService.dispose);
    final child = marked ? MomentFollowUpScreen(
      preloaded: const [
        PendingMoment(date: apk2Day, hhmm: '09:15'),
        PendingMoment(date: apk2Day, hhmm: '10:05'),
      ],
      preloadedAssumed: const [],
      writer: MomentAnswerWriter(),
      service: momentService,
      exporter: null,
      now: reviewNow,
    ) : const DayTimelineScreen(day: apk2Day);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
      ],
      child: MaterialApp(
        navigatorKey: navigator,
        theme: buildTheme(Brightness.light),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(scale), alwaysUse24HourFormat: true),
          child: child!,
        ),
        home: Scaffold(body: SafeArea(child: Column(children: [
          const Text('Outside breakdown'),
          entry ?? TextButton(
            onPressed: () => navigator.currentState!.push(
                MaterialPageRoute<void>(builder: (_) => child)),
            child: const Text('Open breakdown'),
          ),
        ]))),
      ),
    ));
    if (entry == null) await apk2Tap(t, find.text('Open breakdown'));
    await settle(t);
  }

  Future<Map<String, List<Map<String, Object?>>>> snapshot(WidgetTester t) async =>
      (await t.runAsync(() async => {
        for (final table in ['activity_suggestions', 'activity_review_meta',
            'activity_review_days', 'sleep_nap', 'sessions', 'moment_label', 'journal'])
          table: await db.query(table, orderBy: 'rowid'),
      }))!;

  Future<ActivityReviewStatus> status(WidgetTester t, String id) async =>
      (await t.runAsync(() => store.get(id.substring('activity:'.length))))!.status;
}
