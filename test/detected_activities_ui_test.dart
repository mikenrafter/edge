import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/data/nap_resolution.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';

ActivitySuggestion proposal(
  String id,
  ActivityKind kind, {
  int revision = 0,
  int shift = 0,
}) => ActivitySuggestion(
  id: id,
  kind: kind,
  startTs: 1787157000 + shift,
  endTs: 1787158800 + shift,
  revision: revision,
  details: const {'sport': 'unrecognized'},
);

class _Repo extends LocalRepository {
  List<ActivitySuggestion> items = [
    proposal('nap', ActivityKind.nap),
    proposal('workout', ActivityKind.workout),
  ];
  bool fail = false;
  String? savedType;
  @override
  Future<List<ActivitySuggestion>> pendingActivities() async {
    if (fail) throw StateError('offline database');
    return items.toList();
  }

  @override
  Future<int> pendingActivityCount() async {
    if (fail) throw StateError('offline database');
    return items.length;
  }

  @override
  Future<DayReviewReceipt> saveDayReview({required List<ActivityDecision> activities,
      required List<MomentDecision> moments, List<ReviewRange> ranges = const [],
      List<MomentWorkoutDecision> workouts = const [],
      Map<AssumedGlass, bool> glasses = const {}}) async {
    for (final d in activities) {
      if (items.singleWhere((i) => i.id == d.suggestion.id).revision != d.suggestion.revision) {
        throw const ActivityReviewException('The proposal changed. Review the new times.');
      }
    }
    for (final d in activities) {
      if (d.keep) {
        await confirmActivity(d.suggestion, startTs: d.startTs,
            endTs: d.endTs, workoutType: d.workoutType);
      } else {
        await discardActivity(d.suggestion);
      }
    }
    return const DayReviewReceipt();
  }

  @override
  Future<List<SessionSpan>> savedSessionSpans() async => [];
  @override
  Future<void> discardActivity(ActivitySuggestion s) async {
    items.removeWhere((i) => i.id == s.id);
  }

  @override
  Future<void> confirmActivity(
    ActivitySuggestion s, {
    int? startTs,
    int? endTs,
    String? workoutType,
    NapResolution? expected,
  }) async {
    if (items.singleWhere((i) => i.id == s.id).revision != s.revision) {
      throw const ActivityReviewException(
        'The proposal changed. Review the new times.',
      );
    }
    savedType = workoutType;
    items.removeWhere((i) => i.id == s.id);
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'notify_auto_detect': false}),
  );
  Future<_Repo> pump(WidgetTester t, {bool fail = false, Widget? home}) async {
    t.view.physicalSize = const Size(1170, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _Repo()..fail = fail;
    app.repo = repo;
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ThemeController>(
            create: (_) =>
                ThemeController.seed(AppThemeChoice.light, Brightness.light),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: home ?? DayTimelineScreen(
            data: TimelineData(day: dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
                proposal('nap', ActivityKind.nap).startTs * 1000))),
            reviewMoments: const [],
            reviewEditor: const MomentReviewEditor(preloadedAssumed: [])),
        ),
      ),
    );
    await t.pumpAndSettle();
    return repo;
  }

  testWidgets('load failure offers retry and does not claim an empty list', (
    t,
  ) async {
    final repo = await pump(t, fail: true);
    expect(find.text('Could not load activities. Try again.'), findsOneWidget);
    expect(find.text('Nothing to review'), findsNothing);
    repo.fail = false;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('apk2-review-tray')),
        matching: find.text('Possible nap')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('apk2-review-tray')),
        matching: find.text('Possible workout')), findsOneWidget);
    expect(find.byKey(const ValueKey('apk2-review-load-error')), findsNothing);
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> tap(WidgetTester t, String value) async {
    await t.ensureVisible(key(value));
    await t.tap(key(value));
    await t.pumpAndSettle();
  }

  testWidgets('Keep and Discard are staged, then Save removes only chosen items', (t) async {
    final repo = await pump(t);
    await tap(t, 'apk2-review-keep:activity:nap');
    expect(repo.items, hasLength(2));
    await tap(t, 'apk2-review-save');
    expect(repo.items.single.id, 'workout');
    await tap(t, 'apk2-review-discard:activity:workout');
    expect(repo.items, hasLength(1));
    await tap(t, 'apk2-review-save');
    expect(repo.items, isEmpty);
    expect(find.text('Nothing to review'), findsOneWidget);
  });

  testWidgets('cancelling a nap edit leaves it pending and stages nothing', (t) async {
    final repo = await pump(t);
    await tap(t, 'day-review-label:activity:nap');
    expect(find.text('Queue this answer'), findsOneWidget);
    Navigator.of(t.element(find.byType(NapProposalEditor))).pop();
    await t.pumpAndSettle();
    expect(repo.items, hasLength(2));
    await tap(t, 'apk2-review-save');
    expect(repo.items, hasLength(2));
  });

  testWidgets('unknown workout stays Other; stale Save reloads the proposal for retry', (t) async {
    final repo = await pump(t);
    await tap(t, 'day-review-label:activity:workout');
    expect(find.text('Other'), findsOneWidget);
    await t.tap(find.text('Queue this answer'));
    await t.pumpAndSettle();
    expect(repo.items, hasLength(2));
    repo.items[1] = proposal('workout', ActivityKind.workout, revision: 1, shift: 600);
    await tap(t, 'apk2-review-save');
    expect(repo.items, hasLength(2));
    expect(key('apk2-review-save-error'), findsOneWidget);
    await tap(t, 'apk2-review-save');
    expect(repo.items.single.id, 'nap');
    expect(repo.savedType, 'other');
  });

  testWidgets('failed stale-proposal reload does not leave Save stuck', (t) async {
    final repo = await pump(t);
    await tap(t, 'apk2-review-keep:activity:workout');
    repo.items[1] = proposal('workout', ActivityKind.workout, revision: 1, shift: 600);
    repo.fail = true;
    await tap(t, 'apk2-review-save');
    expect(repo.items, hasLength(2));
    expect(key('apk2-review-load-error'), findsOneWidget);
    expect(t.widget<Semantics>(key('apk2-review-save')).properties.enabled, isFalse);
    // A failed reload requires a successful read before Save can retry.
    await tap(t, 'apk2-review-save');
    expect(repo.items, hasLength(2));
    repo.fail = false;
    await tap(t, 'apk2-review-retry');
    expect(key('apk2-review-load-error'), findsNothing);
    expect(t.widget<Semantics>(key('apk2-review-save')).properties.enabled, isTrue);
    await tap(t, 'apk2-review-save');
    expect(repo.items.single.id, 'nap');
    expect(t.widget<Semantics>(key('apk2-review-save')).properties.enabled, isFalse);
  });

  testWidgets('home card stays up when the count fails to load', (t) async {
    await pump(t, fail: true, home: const Scaffold(body: DetectedActivitiesCard()));
    expect(find.text('Detected activities'), findsOneWidget);
    expect(find.text('Could not load activities. Try again.'), findsOneWidget);
  });
}
