import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('meal_review_ui.db'));
  tearDownAll(() => env.dispose());
  testWidgets('meal review title, time edit and Save create only an edited meal', (t) async {
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late DayReviewController review;
    late ActivitySuggestion suggestion;
    final start = DateTime(2026,10,1,12).millisecondsSinceEpoch ~/ 1000;
    await t.runAsync(() async {
      final db = await LocalDb.instance;
      await db.update('activity_review_meta', {'activated_at':0});
      suggestion = (await ActivityStore(db).reconcile(ActivityKind.meal, [{
        'start_ts':start, 'end_ts':start + 1500,
      }])).single;
      review = DayReviewController(LocalRepositoryImpl(getProfileMap: () => {}),
          '2026-10-01', moments: const [], activities: [suggestion],
          editor: const MomentReviewEditor(preloadedAssumed: []));
      await review.load();
    });
    addTearDown(review.dispose);
    final id = 'activity:${suggestion.id}';
    Future<void>? saving;
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(
          alwaysUse24HourFormat: true), child: child!),
      home: Scaffold(body: AnimatedBuilder(animation: review, builder: (c, _) =>
        Column(children: [
          if (review.needsReview(id)) ...[
            Text(review.title(c, id)), Text(review.detail(c, id)),
            ActivityProposalCard(suggestion: suggestion,
              onEdit: () => review.editActivity(c, id),
              onDiscard: () => review.choose(id, false)),
          ],
          TextButton(onPressed: () { saving = review.save(c); }, child: const Text('Save')),
        ])))));
    await t.pumpAndSettle();
    expect(find.text('Possible meal'), findsNWidgets(2));
    expect(find.text('Not a meal'), findsOneWidget);
    expect(find.text('Change sport'), findsNothing);
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await t.tap(find.byTooltip('Switch to text input mode'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(EditableText).at(0), '12');
    await t.enterText(find.byType(EditableText).at(1), '05');
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(find.textContaining('12:05'), findsOneWidget);
    // Start the SQLite write in the real async zone as well as awaiting it.
    // Starting it in fake async can strand sqflite callbacks behind this wait.
    await t.runAsync(() async {
      await t.tap(find.text('Save'));
      await saving!;
    });
    await t.pumpAndSettle();
    expect(review.saveFailed, isFalse);
    await t.runAsync(() async {
      final db = await LocalDb.instance;
      final labels = await LocalDb.momentLabels(date:'2026-10-01');
      expect(labels.map((l) => (l.hhmm,l.label)), [('12:05','meal')]);
      expect(await db.query('sleep_nap'), isEmpty);
      expect(await db.query('sessions'), isEmpty);
      expect(await db.query('food_entry'), isEmpty);
    });
    // Immediate moment reload clears meals even with an older/no derive result.
    expect(review.isSettled(id), isTrue);
    review.reconcileSettled(null);
    expect(review.isSettled(id), isFalse);
    expect(t.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 45)));
}
