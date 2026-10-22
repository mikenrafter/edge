// RED: what the user is told after an import.
//
//  * ImportSummary.needsReentry (from lastImportSummary()) becomes one line per
//    item that was not restored, saying where to enter it again.
//  * A fixed line: band pairing, the Tasker token and the consent answers are
//    device-only and must be set up again.
//  * Both live in the import page's result area, under the ImportReport, and
//    are never shown for an import that failed or landed nothing (the stored
//    summary may belong to an EARLIER import).
//  * The first-run consent prompt is due when consent was loaded and
//    consent_chosen is absent, import or not. Today nothing reads
//    AppState.consentChosen, so no prompt can ever appear.
//
// New strings: stable Key plus English text; ARB keys are in the commit report.
// RED STUBS in lib/: ImportReport.summary, DataScreenView.importSummary,
// AppState.consentLoaded, AppState.consentPromptDue.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import 'step2/support/p23_support.dart';
import 'support/app_state_derive_harness.dart';

const _ok = ImportOutcome(source: 'OpenStrap backup', days: 12);
const _failed = ImportOutcome(source: 'OpenStrap backup', error: 'disk full');
const _empty = ImportOutcome(source: 'OpenStrap backup');
const _lostKey = ImportSummary(needsReentry: [kNeedsReentryCoachKey]);
const _nothingLost = ImportSummary(daysWithRaw: 12);

const _keyLine = ValueKey('post-import-reentry-coach_api_key');
const _deviceLine = ValueKey('post-import-device-only');

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 8000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: ListView(children: [w]))));
  await t.pump();
}

void main() {
  group('ImportReport after a successful import', () {
    testWidgets('one line per item needing re-entry, naming where to enter it',
        (t) async {
      await _pump(t, const ImportReport(_ok, summary: _nothingLost));
      expect(find.byKey(_keyLine), findsNothing,
          reason: 'nothing was lost, so nothing to re-enter');

      await _pump(t, const ImportReport(_ok, summary: _lostKey));
      final line = find.byKey(_keyLine);
      expect(line, findsOneWidget);
      final text = t.widget<Text>(line).data!;
      expect(text, contains('Your AI coach key was not restored.'));
      expect(text, contains('Enter it again in AI settings.'),
          reason: 'the coach key is entered on the Coach "AI settings" screen');
    });

    testWidgets('the fixed device-only line shows with or without a summary',
        (t) async {
      for (final s in [null, _nothingLost, _lostKey]) {
        await _pump(t, ImportReport(_ok, summary: s));
        final line = find.byKey(_deviceLine);
        expect(line, findsOneWidget, reason: 'summary: $s');
        final text = t.widget<Text>(line).data!;
        expect(text, contains('band pairing'));
        expect(text, contains('Tasker token'));
        expect(text, contains('consent'));
      }
    });
  });

  group('never after a failure', () {
    testWidgets('failed or empty outcome hides both notes, stale summary too',
        (t) async {
      // Control: the same summary does show for a good import.
      await _pump(t, const ImportReport(_ok, summary: _lostKey));
      expect(find.byKey(_keyLine), findsOneWidget);
      expect(find.byKey(_deviceLine), findsOneWidget);

      for (final o in [_failed, _empty]) {
        await _pump(t, ImportReport(o, summary: _lostKey));
        expect(find.byKey(_keyLine), findsNothing, reason: '${o.error}');
        expect(find.byKey(_deviceLine), findsNothing, reason: '${o.error}');
      }
    });
  });

  group('placement: the import page result area', () {
    Widget page({ImportOutcome? outcome, ImportSummary? summary, Object? prog}) =>
        DataScreenView(outcome: outcome, importSummary: summary);

    testWidgets('notes sit below the report headline on Your data', (t) async {
      await _pump(t, SizedBox(height: 4000, child: page(outcome: _ok, summary: _lostKey)));
      final headline = t.getTopLeft(find.text('12 days imported')).dy;
      expect(find.byKey(_keyLine), findsOneWidget);
      expect(find.byKey(_deviceLine), findsOneWidget);
      expect(t.getTopLeft(find.byKey(_keyLine)).dy, greaterThan(headline));
      expect(t.getTopLeft(find.byKey(_deviceLine)).dy, greaterThan(headline));
    });

    testWidgets('no outcome (or a failed one): no notes from a stale summary',
        (t) async {
      await _pump(t, SizedBox(height: 4000, child: page(outcome: _ok, summary: _lostKey)));
      expect(find.byKey(_deviceLine), findsOneWidget, reason: 'control');
      await _pump(t, SizedBox(height: 4000, child: page(summary: _lostKey)));
      expect(find.byKey(_keyLine), findsNothing);
      expect(find.byKey(_deviceLine), findsNothing);
      await _pump(t, SizedBox(height: 4000, child: page(outcome: _failed, summary: _lostKey)));
      expect(find.byKey(_deviceLine), findsNothing);
    });
  });

  group('first-run consent prompt', () {
    const name = 'post_import_consent.db';
    late Directory tmp;
    late AppState app;

    setUp(() async {
      await deriveDbSetUp(name);
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('post_import_');
      app = AppState.forTesting();
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    });
    tearDown(() async {
      app.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
      await deriveDbTearDown(name);
    });

    test('due once consent is loaded and unanswered; never before, never after',
        () {
      expect(app.consentPromptDue, isFalse, reason: 'not loaded yet: no flash');
      app.consentLoaded = true;
      expect(app.consentChosen, isFalse);
      expect(app.consentPromptDue, isTrue,
          reason: 'nothing reads consentChosen today, so no prompt exists');
      app.consentChosen = true;
      expect(app.consentPromptDue, isFalse);
    });

    test('an import that leaves consent_chosen absent still reaches the prompt',
        () async {
      final db = await LocalDb.instance;
      await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 70),
          computedAt: 4000, readinessColumn: 70);
      final path = p.join(tmp.path, 'backup.db');
      await db.execute('VACUUM INTO ?', [path]);
      await LocalDb.deleteDays({p23Day(1)});
      app.debugFinalizeImport = _NoRollup();
      app.consentLoaded = true;

      await app.importEdgeBackup(path);

      expect((await SharedPreferences.getInstance()).containsKey('consent_chosen'),
          isFalse, reason: 'device-only: an import must not mark it answered');
      expect(app.consentChosen, isFalse);
      expect(app.consentPromptDue, isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

class _NoRollup implements ImportRollupProbe {
  @override
  Future<void> finalize(profile) async {}
}
