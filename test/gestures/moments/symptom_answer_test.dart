// Answering a marked moment "Symptom" with a description (RED).
//
// Design under test (the owner confirms it in the RED report):
//   * A new additive table `symptom_entry`, keyed on the SAME local
//     (date, hhmm) as the moment, holds the structured description:
//       date, hhmm, severity, side (NULL = not said), kind, kind_other,
//       area, area_other, note, created_at.
//     Why not a journal tag/note: the journal day is (tags, one note) and the
//     numeric journal_metric rows are doses/ratings; text appended to the note
//     would have to be parsed back out, and a metric row would invite scoring.
//     A table keeps it queryable, additive, and apart from every metric.
//   * `MomentAnswerWriter.answerSymptom(m, description)` writes the
//     moment_label (label 'symptom') AND the symptom_entry row in ONE
//     transaction, on the moment's local day at its minute; an answered moment
//     is left alone.
//   * No score or metric is derived: no journal_metric row, no session, no
//     sleep row.
//   * The description shows in the journal and as the moment's label.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _m = PendingMoment(date: '2026-10-06', hhmm: '10:15');
const _m2 = PendingMoment(date: '2026-10-06', hhmm: '15:40');
final _now = DateTime(2026, 10, 7, 12, 0);
const _writer = MomentAnswerWriter();

const _knee = SymptomDescription(
  severity: SymptomSeverity.moderate,
  side: SymptomSide.left,
  kind: SymptomKind.pain,
  area: SymptomArea.knees,
);

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

var _n = 0;
Future<void> _fresh(List<String> created) async {
  final name = 'openstrap_symptom_answer_${_n++}.db';
  created.add(name);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
  await LocalDb.putJournal(
      _m.date, '["moment 10:15","moment 15:40"]', 'a note');
}

Future<List<Map<String, Object?>>> _all(String table) async =>
    (await LocalDb.instance).query(table);

class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => const {};
  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => kJournalFields;
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      const {};
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _path(n));
    }
  });
  setUp(() => _fresh(created));

  group('the writer', () {
    test('stores the label and the structured entry on the moment\'s day at '
        'its minute', () async {
      final r = await _writer.answerSymptom(_m, _knee, now: _now);
      expect(r, MomentAnswerResult.saved);

      final l = (await LocalDb.momentLabels(date: _m.date)).single;
      expect(l.label, 'symptom');
      expect(l.hhmm, '10:15');
      expect(l.note, isNull, reason: 'the structure is not flattened into text');
      expect(l.answeredAtMs, _now.millisecondsSinceEpoch);

      final row = (await _all('symptom_entry')).single;
      expect(row['date'], '2026-10-06', reason: 'the moment\'s day, not today');
      expect(row['hhmm'], '10:15');
      expect(row['severity'], 'moderate');
      expect(row['side'], 'left');
      expect(row['kind'], 'pain');
      expect(row['kind_other'], isNull);
      expect(row['area'], 'knees');
      expect(row['area_other'], isNull);
      expect(row['note'], isNull);
      expect(row['created_at'], _now.millisecondsSinceEpoch);
    });

    test('reads back as a StoredSymptom', () async {
      await _writer.answerSymptom(_m, _knee, now: _now);
      final s = (await LocalDb.symptomEntries(date: _m.date)).single;
      expect(s.date, '2026-10-06');
      expect(s.hhmm, '10:15');
      expect(s.key, '2026-10-06 10:15');
      expect(s.description.severity, SymptomSeverity.moderate);
      expect(s.description.side, SymptomSide.left);
      expect(s.description.kind, SymptomKind.pain);
      expect(s.description.area, SymptomArea.knees);
      expect(s.description.describe(null), 'moderate pain in my knees (left)');
    });

    test('side not said is NULL, free text is kept, multi-word area ids are '
        'stored as ids', () async {
      await _writer.answerSymptom(
          _m,
          const SymptomDescription(
            severity: SymptomSeverity.severe,
            kind: SymptomKind.other,
            kindOther: 'burning',
            area: SymptomArea.other,
            areaOther: 'big toe',
            note: 'after the run',
          ),
          now: _now);
      await _writer.answerSymptom(
          _m2,
          const SymptomDescription(
            severity: SymptomSeverity.faint,
            kind: SymptomKind.soreness,
            area: SymptomArea.lowerBack,
          ),
          now: _now);
      final rows = await _all('symptom_entry');
      final a = rows.firstWhere((r) => r['hhmm'] == '10:15');
      expect(a['side'], isNull);
      expect(a['kind'], 'other');
      expect(a['kind_other'], 'burning');
      expect(a['area'], 'other');
      expect(a['area_other'], 'big toe');
      expect(a['note'], 'after the run');
      final b = rows.firstWhere((r) => r['hhmm'] == '15:40');
      expect(b['area'], 'lower_back');
      expect(b['side'], isNull);
    });

    test('free text is trimmed before it is stored', () async {
      await _writer.answerSymptom(
          _m,
          const SymptomDescription(
            severity: SymptomSeverity.mild,
            kind: SymptomKind.other,
            kindOther: '  stinging  ',
            area: SymptomArea.hands,
          ),
          now: _now);
      expect((await _all('symptom_entry')).single['kind_other'], 'stinging');
    });

    test('"other" with no text is refused and writes nothing at all', () async {
      for (final d in const [
        SymptomDescription(
            severity: SymptomSeverity.mild,
            kind: SymptomKind.other,
            area: SymptomArea.hands),
        SymptomDescription(
            severity: SymptomSeverity.mild,
            kind: SymptomKind.other,
            kindOther: '   ',
            area: SymptomArea.hands),
        SymptomDescription(
            severity: SymptomSeverity.mild,
            kind: SymptomKind.pain,
            area: SymptomArea.other),
      ]) {
        await expectLater(_writer.answerSymptom(_m, d, now: _now),
            throwsArgumentError);
      }
      expect(await _all('symptom_entry'), isEmpty);
      expect(await LocalDb.momentLabels(), isEmpty,
          reason: 'the moment stays unanswered');
    });

    test('no score or metric is derived: no journal_metric, session, nap or '
        'sleep row; the journal day is untouched', () async {
      await _writer.answerSymptom(_m, _knee, now: _now);
      expect(await _all('journal_metric'), isEmpty);
      expect(await _all('sessions'), isEmpty);
      expect(await _all('sleep_nap'), isEmpty);
      expect(await _all('sleep_override'), isEmpty);
      final j = (await _all('journal')).single;
      expect(j['tags_json'], '["moment 10:15","moment 15:40"]');
      expect(j['note'], 'a note');
    });

    test('a moment is answered once: a second description is ignored',
        () async {
      await _writer.answerSymptom(_m, _knee, now: _now);
      final again = await _writer.answerSymptom(
          _m,
          const SymptomDescription(
              severity: SymptomSeverity.severe,
              kind: SymptomKind.swelling,
              area: SymptomArea.ankles),
          now: _now);
      expect(again, MomentAnswerResult.alreadyAnswered);
      final rows = await _all('symptom_entry');
      expect(rows, hasLength(1));
      expect(rows.single['area'], 'knees');
    });

    test('a moment already skipped or labelled another way gets no entry',
        () async {
      await _writer.skip(_m, now: _now);
      await _writer.answer(_m2, MomentChoice.nap, now: _now);
      expect(await _writer.answerSymptom(_m, _knee, now: _now),
          MomentAnswerResult.alreadyAnswered);
      expect(await _writer.answerSymptom(_m2, _knee, now: _now),
          MomentAnswerResult.alreadyAnswered);
      expect(await _all('symptom_entry'), isEmpty);
    });

    test('two moments answered at once both land', () async {
      final rs = await Future.wait([
        _writer.answerSymptom(_m, _knee, now: _now),
        _writer.answerSymptom(_m2, _knee, now: _now),
      ]);
      expect(rs, everyElement(MomentAnswerResult.saved));
      expect(await _all('symptom_entry'), hasLength(2));
    });

    test('the same moment answered at once is one entry', () async {
      final rs = await Future.wait([
        _writer.answerSymptom(_m, _knee, now: _now),
        _writer.answerSymptom(_m, _knee, now: _now),
      ]);
      expect(rs.where((r) => r == MomentAnswerResult.saved), hasLength(1));
      expect(await _all('symptom_entry'), hasLength(1));
    });

    test('an answered symptom moment is no longer pending', () async {
      await _writer.answerSymptom(_m, _knee, now: _now);
      final f = await MomentFollowUps.load(enabledSince: DateTime(2026, 10, 1));
      expect([for (final x in f.pending(_now)) x.key], [_m2.key]);
    });

    test('symptomEntries narrows by day and since, in time order', () async {
      await LocalDb.putJournal('2026-10-05', '["moment 08:00"]', '');
      const early = PendingMoment(date: '2026-10-05', hhmm: '08:00');
      await _writer.answerSymptom(_m2, _knee, now: _now);
      await _writer.answerSymptom(_m, _knee, now: _now);
      await _writer.answerSymptom(early, _knee, now: _now);
      expect([for (final s in await LocalDb.symptomEntries(date: _m.date)) s.hhmm],
          ['10:15', '15:40']);
      expect(await LocalDb.symptomEntries(sinceDate: '2026-10-06'),
          hasLength(2));
      expect(await LocalDb.symptomEntries(), hasLength(3));
    });
  });

  group('shown as the moment label', () {
    final dayStart = DateTime(2026, 10, 6).millisecondsSinceEpoch ~/ 1000;
    const label = MomentLabel(
        date: '2026-10-06', hhmm: '10:15', label: 'symptom', answeredAtMs: 1);
    const stored = StoredSymptom(
        date: '2026-10-06', hhmm: '10:15', description: _knee);

    test('the timeline line is the description', () {
      final m = dayMoments(
        timeline: {'day_start': dayStart},
        momentLabels: [label],
        symptoms: [stored],
      );
      expect(m, hasLength(1));
      expect(m.single.title, contains('moderate pain in my knees (left)'));
      expect(m.single.detail, contains('10:15'));
    });

    test('a symptom label with no stored description (answered before this '
        'existed) still reads "Symptom"', () {
      final m = dayMoments(
          timeline: {'day_start': dayStart}, momentLabels: [label]);
      expect(m.single.title, contains('Symptom'));
    });

    test('the description is matched to ITS moment only', () {
      final m = dayMoments(
        timeline: {'day_start': dayStart},
        momentLabels: [
          label,
          const MomentLabel(
              date: '2026-10-06',
              hhmm: '15:40',
              label: 'symptom',
              answeredAtMs: 1),
        ],
        symptoms: [stored],
      );
      expect(m[0].title, contains('moderate pain in my knees (left)'));
      expect(m[1].title, contains('Symptom'));
      expect(m[1].title.contains('knees'), isFalse);
    });
  });

  group('shown in the journal', () {
    testWidgets('the compose screen lists the day\'s symptoms by time',
        (t) async {
      await t.runAsync(() async {
        await _writer.answerSymptom(_m2, _knee, now: _now);
        await _writer.answerSymptom(
            _m,
            const SymptomDescription(
                severity: SymptomSeverity.mild,
                kind: SymptomKind.itchiness,
                area: SymptomArea.neck),
            now: _now);
      });
      t.view.physicalSize = const Size(390 * 3, 4000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.repo = _Repo();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
            value: app, child: const JournalCompose(date: '2026-10-06')),
      ));
      final neck = find.textContaining('mild itchiness in my neck');
      for (var i = 0; i < 60 && neck.evaluate().isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      final knee = find.textContaining('moderate pain in my knees (left)');
      expect(neck, findsOneWidget);
      expect(knee, findsOneWidget);
      expect(t.getTopLeft(neck).dy, lessThan(t.getTopLeft(knee).dy),
          reason: '10:15 above 15:40');
      expect(find.textContaining('10:15'), findsWidgets);
    });

    testWidgets('a day with no symptoms shows nothing about symptoms',
        (t) async {
      t.view.physicalSize = const Size(390 * 3, 4000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.repo = _Repo();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
            value: app, child: const JournalCompose(date: '2026-10-06')),
      ));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(find.textContaining(' in my '), findsNothing);
    });
  });
}
