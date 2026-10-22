// One source for "what is happening now" (RULES B.3: work never runs hidden).
//
// 1. ImportGate: SyncCoordinator.view.phase == 'waiting_import' is NEUTRAL on
//    every surface that switches on the phase string. It says "Waiting for the
//    import to finish" (the ImportGate sentence, also the failureReason once
//    syncNow() refused), never an error, a failure, an offline state or red.
// 2. The band sync sheet's headline follows the ACTIVE step. Owner bug: it read
//    "Downloaded · synced through Thu 22 Oct, 01:20" while the step list showed
//    Calculate running ("Waiting for another calculation") and Done waiting.
//
// The tests run without localization delegates, so the UI's English fallbacks
// are what is pinned. The new headline wording is "Calculating · waiting for
// another calculation" (an ARB string the implementer adds); the test matches
// it case-insensitively on its two clauses.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/sync/import_gate.dart';
import 'package:openstrap_edge/ui2/status_line.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _t0 = DateTime(2026, 10, 22, 1, 0);
final _now = DateTime(2026, 10, 22, 1, 30);

/// The sentence ImportGate publishes; the only source of the wording.
final _waiting = const SyncRefused(ImportBlock.importRunning).message;

class _App extends AppState {
  _App(this.pres) : super.forTesting();
  SyncPresentationState pres;
  final derive = ValueNotifier<DeriveProgress?>(null);

  @override
  SyncPresentationState get syncPresentation => pres;
  @override
  ValueListenable<DeriveProgress?> get deriveProgress => derive;
}

/// What SyncCoordinator.view returns during an import: not busy, phase
/// 'waiting_import'. [reason] is the failureReason (null on the passive view,
/// the sentence after syncNow() refused, possibly a stale failure).
SyncPresentationState _waitingImport({String? reason, bool success = true}) =>
    SyncPresentationState(
      phase: 'waiting_import',
      failureReason: reason,
      lastSuccess: success ? DateTime(2026, 10, 22, 0, 40) : null,
    );

Widget _host(Widget body, {AppState? app}) {
  Widget b = body;
  if (app != null) {
    b = ChangeNotifierProvider<AppState>.value(value: app, child: b);
  }
  return MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: b)),
  );
}

SyncStep _s(SyncStepId id, SyncStepStatus st,
        {int? start, int? end, SyncDownloadDetail? download,
        SyncCalculateDetail? calculate}) =>
    SyncStep(
      id: id,
      status: st,
      startedAt: start == null ? null : _t0.add(Duration(seconds: start)),
      endedAt: end == null ? null : _t0.add(Duration(seconds: end)),
      download: download,
      calculate: calculate,
    );

/// Owner's screenshot: download finished (synced through 01:20), Calculate is
/// running but queued behind another calculation, Done not started.
SyncPresentationState _calcWaiting() => SyncPresentationState(
      phase: 'deriving',
      busy: true,
      contactedBand: true,
      startedAt: _t0,
      steps: [
        _s(SyncStepId.connect, SyncStepStatus.done, start: 0, end: 2),
        _s(SyncStepId.download, SyncStepStatus.done,
            start: 2,
            end: 60,
            download: SyncDownloadDetail(
                records: 41800,
                chunks: 104,
                syncedThrough: DateTime(2026, 10, 22, 1, 20))),
        _s(SyncStepId.calculate, SyncStepStatus.running,
            start: 60, calculate: const SyncCalculateDetail(waiting: true)),
        _s(SyncStepId.done, SyncStepStatus.waiting),
      ],
    );

Iterable<String> _texts(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '');

/// No wording or mark of an error, a failure or a missing band.
void _expectNeutral(WidgetTester t, {bool checkMarks = true}) {
  for (final s in _texts(t)) {
    final low = s.toLowerCase();
    expect(low, isNot(contains('fail')), reason: 'error wording: "$s"');
    expect(low, isNot(contains('not connected')), reason: 'offline: "$s"');
    expect(low, isNot(contains('offline')), reason: 'offline: "$s"');
    expect(s, isNot('Retry'), reason: 'a retry is not offered while waiting');
  }
  if (checkMarks) {
    for (final icon in [LucideIcons.circleX, LucideIcons.unplug]) {
      expect(find.byIcon(icon), findsNothing, reason: 'error/offline mark');
    }
  }
}

void main() {
  group('ImportGate: waiting_import is neutral', () {
    for (final reason in <String?>[null, _waiting]) {
      final label = reason == null ? 'passive view (no reason)' : 'refused syncNow';

      testWidgets('StatusLine, $label', (t) async {
        final app = _App(_waitingImport(reason: reason));
        addTearDown(app.dispose);
        await t.pumpWidget(_host(StatusLine(todayId: '2026-10-22', now: _now),
            app: app));
        final line = find.descendant(
            of: find.byType(StatusLine), matching: find.byType(Text));
        expect(line, findsWidgets);
        expect(t.widget<Text>(line.first).data, _waiting);
        _expectNeutral(t);
      });

      testWidgets('StatusLine with sync actions (Home header), $label',
          (t) async {
        final app = _App(_waitingImport(reason: reason));
        addTearDown(app.dispose);
        await t.pumpWidget(_host(
            StatusLine(
                todayId: '2026-10-22',
                now: _now,
                syncActions: true,
                idleLabel: 'Thu 22 Oct'),
            app: app));
        expect(find.text(_waiting), findsOneWidget);
        _expectNeutral(t);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('sync control panel, $label', (t) async {
        await t.pumpWidget(_host(SyncControl(
            state: _waitingImport(reason: reason),
            onSync: () {},
            clock: () => _now)));
        expect(find.text(_waiting), findsOneWidget);
        _expectNeutral(t);
        // The success tick that "last synced" earns would say "all is well".
        expect(find.byIcon(LucideIcons.circleCheck), findsNothing);
        // Not red: the sentence is drawn in the ordinary ink.
        final red = P.of(t.element(find.text(_waiting))).on(C.red);
        expect(t.widget<Text>(find.text(_waiting)).style?.color, isNot(red));
      });
    }

    testWidgets('a stale failure reason does not outrank the import', (t) async {
      await t.pumpWidget(_host(SyncControl(
          state: _waitingImport(reason: 'Could not reach the band'),
          onSync: () {},
          clock: () => _now)));
      expect(find.text(_waiting), findsOneWidget);
      expect(find.textContaining('Could not reach'), findsNothing);
    });

    testWidgets('sync control panel, no earlier success', (t) async {
      await t.pumpWidget(_host(SyncControl(
          state: _waitingImport(success: false),
          onSync: () {},
          clock: () => _now)));
      expect(find.text(_waiting), findsOneWidget);
      _expectNeutral(t);
    });

    testWidgets('band sync sheet', (t) async {
      final app = _App(_waitingImport());
      addTearDown(app.dispose);
      await t.pumpWidget(_host(
          Builder(
              builder: (c) => TextButton(
                  onPressed: () => showSyncDetails(c, app),
                  child: const Text('open'))),
          app: app));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text(_waiting), findsOneWidget);
      _expectNeutral(t);
    });
  });

  group('sheet headline follows the active step', () {
    Future<void> openSheet(WidgetTester t, _App app) async {
      await t.pumpWidget(_host(
          Builder(
              builder: (c) => TextButton(
                  onPressed: () => showSyncDetails(c, app),
                  child: const Text('open'))),
          app: app));
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 400));
    }

    final waitingHeadline =
        RegExp(r'^calculating\b.*waiting for another calculation',
            caseSensitive: false);

    test('the sentence itself (pure)', () {
      final line = syncStatusLine(_calcWaiting(), _now);
      expect(line, matches(waitingHeadline));
      expect(line, isNot(contains('Downloaded')));
      expect(line, isNot(contains('synced through')));
    });

    testWidgets('Download done, Calculate waiting: calculating, not downloaded',
        (t) async {
      final app = _App(_calcWaiting());
      addTearDown(app.dispose);
      await openSheet(t, app);
      final headlines = _texts(t).where(waitingHeadline.hasMatch);
      expect(headlines, hasLength(1),
          reason: 'headline names the active step and what it waits for; '
              'texts: ${_texts(t).toList()}');
      expect(_texts(t).where((s) => s.startsWith('Downloaded')), isEmpty,
          reason: 'the finished download is the Download row\'s to tell');
      expect(_texts(t).where((s) => s.contains('synced through')), isEmpty,
          reason: '"synced through" belongs to a finished sync');
      // The step list still shows the same fact: headline and row agree.
      expect(find.textContaining('aiting for another calculation'),
          findsNWidgets(2),
          reason: 'headline + Calculate row, both from the active step');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the sync control panel headline agrees', (t) async {
      await t.pumpWidget(_host(SyncControl(
          state: _calcWaiting(), onSync: () {}, clock: () => _now)));
      expect(_texts(t).where(waitingHeadline.hasMatch), hasLength(1),
          reason: 'texts: ${_texts(t).toList()}');
      expect(_texts(t).where((s) => s.startsWith('Downloaded')), isEmpty);
      await t.pumpWidget(const SizedBox());
    });
  });
}
