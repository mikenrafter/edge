// 8AF.7 section E (red first): the sync panel collapses to ONE status line.
//
//   [elapsed]  icon / spinner  ·  one sentence  ·  at most one action
//
// Tap the line to expand today's step list inline (collapsed by default, open
// or closed remembered under the persisted key 'sync-details'). Always visible
// on Home, including idle. No estimated counts (AGENTS.md 4.1).
//
// Contracts these tests pin that the spec leaves open:
//  - "idle" is a phase string: SyncPresentationState(phase: 'idle'). Phase
//    'offline' stays "the band is not connected / was not contacted".
//  - A step is "expanded into view" when its label (Connect, Download,
//    Calculate, Done) is in the tree; collapsed means none of them is.
//  - The elapsed readout is the m:ss text the panel always drew ("1:15"); it
//    sits LEFT of the status sentence on the same row.
//  - Spinner = a CircularProgressIndicator; the action is a text button whose
//    label is exactly 'Sync now' or 'Retry'.
//  - Time wording: "Synced 12 min ago", "synced 3 h ago", band time as
//    "2 h 10 min".
// See docs/proof-workflow.md for the structural-fixture convention.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _t0 = DateTime(2026, 9, 30, 9, 15);

/// 75 s into a sync that started at [_t0].
DateTime _running() => _t0.add(const Duration(seconds: 75));

/// A fixed "now" for the settled phases.
final _noon = DateTime(2026, 9, 30, 12, 0);
DateTime _atNoon() => _noon;

SyncStep _s(
  SyncStepId id,
  SyncStepStatus status, {
  int? start,
  int? end,
  String? note,
  SyncDownloadDetail? download,
  SyncCalculateDetail? calculate,
}) =>
    SyncStep(
      id: id,
      status: status,
      startedAt: start == null ? null : _t0.add(Duration(seconds: start)),
      endedAt: end == null ? null : _t0.add(Duration(seconds: end)),
      note: note,
      download: download,
      calculate: calculate,
    );

SyncPresentationState _busy(String phase, List<SyncStep> steps) =>
    SyncPresentationState(
      phase: phase,
      busy: true,
      contactedBand: true,
      startedAt: _t0,
      steps: steps,
    );

SyncPresentationState _downloading(SyncDownloadDetail d,
        {SyncStepStatus status = SyncStepStatus.running}) =>
    _busy('downloading', [
      _s(SyncStepId.connect, SyncStepStatus.done, start: 0, end: 2),
      _s(SyncStepId.download, status, start: 2, download: d),
      _s(SyncStepId.calculate, SyncStepStatus.waiting),
      _s(SyncStepId.done, SyncStepStatus.waiting),
    ]);

/// 07:00 banked, the band says it holds up to 09:10: 2 h 10 min to go.
SyncPresentationState _withBacklog() => _downloading(SyncDownloadDetail(
      records: 12400,
      chunks: 31,
      syncedThrough: DateTime(2026, 9, 30, 7, 0),
      bandNewest: DateTime(2026, 9, 30, 9, 10),
    ));

/// Banked something, the band has not said how much it holds.
SyncPresentationState _noBacklog() => _downloading(SyncDownloadDetail(
      records: 3000,
      chunks: 8,
      syncedThrough: DateTime(2026, 9, 30, 8, 0),
    ));

SyncPresentationState _nothingNew() => _downloading(
      const SyncDownloadDetail(),
      status: SyncStepStatus.done,
    );

SyncPresentationState _deriving(SyncCalculateDetail? d,
        {SyncDownloadDetail? download}) =>
    _busy('deriving', [
      _s(SyncStepId.connect, SyncStepStatus.skipped,
          note: 'Already connected'),
      _s(SyncStepId.download,
          download == null ? SyncStepStatus.skipped : SyncStepStatus.done,
          start: 0, end: 58, download: download),
      _s(SyncStepId.calculate, SyncStepStatus.running,
          start: 58, calculate: d),
      _s(SyncStepId.done, SyncStepStatus.waiting),
    ]);

SyncPresentationState _failed({String? reason, String? error}) =>
    SyncPresentationState(
      phase: 'failed',
      error: error,
      failureReason: reason,
      lastSuccess: DateTime(2026, 9, 29, 7, 40),
      startedAt: _t0,
      finishedAt: _t0.add(const Duration(seconds: 41)),
      steps: [
        _s(SyncStepId.connect, SyncStepStatus.done, start: 0, end: 3),
        _s(SyncStepId.download, SyncStepStatus.failed,
            start: 3,
            end: 41,
            download: const SyncDownloadDetail(records: 2200, chunks: 6)),
        _s(SyncStepId.calculate, SyncStepStatus.skipped, note: 'Not reached'),
        _s(SyncStepId.done, SyncStepStatus.skipped, note: 'Not reached'),
      ],
    );

SyncPresentationState _completed({bool partial = false}) =>
    SyncPresentationState(
      phase: 'completed',
      contactedBand: true,
      partial: partial,
      lastSuccess: _t0.add(const Duration(seconds: 70)),
      startedAt: _t0,
      finishedAt: _t0.add(const Duration(seconds: 70)),
      steps: [
        _s(SyncStepId.connect, SyncStepStatus.done, start: 0, end: 3),
        _s(SyncStepId.download, SyncStepStatus.done,
            start: 3,
            end: 50,
            download: SyncDownloadDetail(
                records: 41800,
                chunks: 104,
                syncedThrough: DateTime(2026, 9, 30, 9, 10))),
        _s(SyncStepId.calculate, SyncStepStatus.done, start: 50, end: 70),
        _s(SyncStepId.done, SyncStepStatus.done, start: 70, end: 70),
      ],
    );

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    );

Widget _control(SyncPresentationState s,
        {DateTime Function()? clock, VoidCallback? onSync, Key? key}) =>
    _host(SyncControl(
      key: key,
      state: s,
      onSync: onSync ?? () {},
      clock: clock ?? _running,
    ));

/// Prefs written in the background need real time to land.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump();
  }
}

const _stepLabels = ['Connect', 'Download', 'Calculate', 'Done'];

void _expectCollapsed() {
  for (final l in _stepLabels) {
    expect(find.text(l), findsNothing, reason: '$l visible while collapsed');
  }
}

void _expectExpanded() {
  for (final l in _stepLabels) {
    expect(find.text(l), findsOneWidget, reason: '$l missing when expanded');
  }
}

/// A busy-state test must not leave the 1 s ticker running.
void _tw(String name, Future<void> Function(WidgetTester t) body) =>
    testWidgets(name, (t) async {
      await body(t);
      await t.pumpWidget(const SizedBox());
    });

void _expectLine(WidgetTester t, String line,
    {String? action, bool spinner = false, String? reason}) {
  expect(find.text(line), findsOneWidget, reason: reason ?? 'status "$line"');
  expect(find.byType(CircularProgressIndicator),
      spinner ? findsOneWidget : findsNothing,
      reason: spinner ? 'busy: a spinner' : 'settled: no spinner');
  for (final a in const ['Sync now', 'Retry']) {
    expect(find.text(a), a == action ? findsOneWidget : findsNothing,
        reason: action == null
            ? 'no action expected, found "$a"'
            : 'only "$action" expected');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('every phase is one sentence', () {
    _tw('idle, has synced', (t) async {
      await t.pumpWidget(_control(
        SyncPresentationState(
            phase: 'idle', lastSuccess: _noon.subtract(const Duration(minutes: 12))),
        clock: _atNoon,
      ));
      _expectLine(t, 'Synced 12 min ago', action: 'Sync now');
    });

    _tw('idle, never synced', (t) async {
      await t.pumpWidget(
          _control(const SyncPresentationState(phase: 'idle'), clock: _atNoon));
      _expectLine(t, 'Not synced yet', action: 'Sync now');
    });

    _tw('offline: says the band is not connected and when it last synced',
        (t) async {
      await t.pumpWidget(_control(
        SyncPresentationState(
            phase: 'offline', lastSuccess: _noon.subtract(const Duration(hours: 3))),
        clock: _atNoon,
      ));
      _expectLine(t, 'Band not connected · synced 3 h ago', action: 'Sync now');
    });

    _tw('connecting', (t) async {
      await t.pumpWidget(_control(_busy('connecting', [
        _s(SyncStepId.connect, SyncStepStatus.running, start: 0),
        _s(SyncStepId.download, SyncStepStatus.waiting),
        _s(SyncStepId.calculate, SyncStepStatus.waiting),
        _s(SyncStepId.done, SyncStepStatus.waiting),
      ])));
      _expectLine(t, 'Connecting to the band…', spinner: true);
    });

    _tw('downloading with a known backlog', (t) async {
      await t.pumpWidget(_control(_withBacklog()));
      _expectLine(t, 'Downloading · 2 h 10 min of band time to go',
          spinner: true);
    });

    _tw('downloading, backlog not known: no number is invented', (t) async {
      await t.pumpWidget(_control(_noBacklog()));
      _expectLine(t, 'Downloading…', spinner: true);
      expect(find.textContaining('to go'), findsNothing);
    });

    _tw('downloading, the band has nothing new', (t) async {
      await t.pumpWidget(_control(_nothingNew()));
      _expectLine(t, 'Nothing new on the band', spinner: true);
    });

    _tw('deriving, day known', (t) async {
      await t.pumpWidget(_control(_deriving(const SyncCalculateDetail(
          dayIndex: 3, dayTotal: 7, day: '2026-09-29'))));
      _expectLine(t, 'Calculating · day 3 of 7', spinner: true);
    });

    _tw('deriving, day not known: "Calculating" and no day number', (t) async {
      await t.pumpWidget(_control(_deriving(const SyncCalculateDetail())));
      expect(
          find.byWidgetPredicate((w) =>
              w is Text &&
              (w.data ?? '').startsWith('Calculating') &&
              !(w.data ?? '').contains('day')),
          findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Sync now'), findsNothing);
    });

    _tw('waiting on another calculation, with download detail: that line',
        (t) async {
      await t.pumpWidget(_control(_deriving(
        const SyncCalculateDetail(waiting: true),
        download: SyncDownloadDetail(
            records: 41800,
            chunks: 104,
            syncedThrough: DateTime(2026, 9, 30, 14, 32)),
      )));
      expect(
          find.byWidgetPredicate((w) =>
              w is Text &&
              RegExp(r'^Downloaded · synced through .*14:32$')
                  .hasMatch(w.data ?? '')),
          findsOneWidget);
      expect(find.text('Waiting for another calculation…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    _tw('waiting, the band had nothing new: says so', (t) async {
      await t.pumpWidget(_control(_deriving(
        const SyncCalculateDetail(waiting: true),
        download: const SyncDownloadDetail(),
      )));
      _expectLine(t, 'Nothing new on the band', spinner: true);
      expect(find.text('Waiting for another calculation…'), findsNothing);
    });

    _tw('waiting, a backlog is known: one download line, not the fallback',
        (t) async {
      await t.pumpWidget(_control(_deriving(
        const SyncCalculateDetail(waiting: true),
        download: SyncDownloadDetail(
            records: 12,
            chunks: 1,
            syncedThrough: DateTime(2026, 9, 30, 7, 0),
            bandNewest: DateTime(2026, 9, 30, 9, 10)),
      )));
      expect(find.text('Waiting for another calculation…'), findsNothing);
      final backlog = find.text('2 h 10 min of band time still to fetch');
      final through = find.byWidgetPredicate((w) =>
          w is Text && (w.data ?? '').startsWith('Downloaded · synced through'));
      expect(
          backlog.evaluate().length + through.evaluate().length, 1,
          reason: 'exactly one most-useful download line');
    });

    _tw('waiting with no download detail at all: the honest fallback',
        (t) async {
      await t.pumpWidget(_control(
          _deriving(const SyncCalculateDetail(waiting: true))));
      _expectLine(t, 'Waiting for another calculation…', spinner: true);
    });

    _tw('completed: "Synced just now"', (t) async {
      await t.pumpWidget(_control(_completed(),
          clock: () => _t0.add(const Duration(seconds: 80))));
      _expectLine(t, 'Synced just now', action: 'Sync now');
    });

    _tw('completed partly: says some days need another pass', (t) async {
      await t.pumpWidget(_control(_completed(partial: true),
          clock: () => _t0.add(const Duration(seconds: 80))));
      _expectLine(t, 'Synced, but some days need another pass',
          action: 'Sync now');
    });

    _tw('failed: the reason, in red, with Retry', (t) async {
      await t.pumpWidget(_control(_failed(
          reason: 'Band disconnected during sync',
          error: 'Bad state: Band disconnected during sync')));
      _expectLine(t, 'Sync failed: Band disconnected during sync',
          action: 'Retry');
      final text = t.widget<Text>(
          find.text('Sync failed: Band disconnected during sync'));
      final p = P.of(t.element(find.byType(SyncControl)));
      expect(text.style?.color, p.on(C.red), reason: 'the failure is red');
    });

    _tw('failed with no reason at all still has one', (t) async {
      await t.pumpWidget(_control(_failed()));
      _expectLine(t, 'Sync failed: Please retry', action: 'Retry');
    });
  });

  group('the elapsed timer', () {
    _tw('sits LEFT of the status text, on the same row, while running',
        (t) async {
      await t.pumpWidget(_control(_withBacklog(),
          clock: () => _t0.add(const Duration(seconds: 42))));
      final timer = find.text('0:42');
      final status = find.text('Downloading · 2 h 10 min of band time to go');
      expect(timer, findsOneWidget);
      expect(status, findsOneWidget);
      expect(t.getTopLeft(timer).dx, lessThan(t.getTopLeft(status).dx));
      expect((t.getCenter(timer).dy - t.getCenter(status).dy).abs(),
          lessThan(8),
          reason: 'one row, not a header above a sentence');
    });

    _tw('ticks: still left of the status a second later', (t) async {
      var now = _t0.add(const Duration(seconds: 42));
      await t.pumpWidget(_control(_withBacklog(), clock: () => now));
      now = now.add(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('0:43'), findsOneWidget);
    });

    _tw('is not shown when idle, completed or failed', (t) async {
      final timer = find.byWidgetPredicate(
          (w) => w is Text && RegExp(r'^\d+:\d\d(:\d\d)?$').hasMatch(w.data ?? ''));
      for (final s in [
        SyncPresentationState(
            phase: 'idle', lastSuccess: _noon.subtract(const Duration(minutes: 12))),
        _completed(),
        _failed(reason: 'Band disconnected during sync'),
      ]) {
        await t.pumpWidget(_control(s, clock: () => _t0.add(const Duration(seconds: 80))));
        expect(timer, findsNothing, reason: '${s.phase} shows no timer');
      }
    });
  });

  group('one row, one action', () {
    _tw('the action is on the same row as the sentence', (t) async {
      await t.pumpWidget(_control(
        SyncPresentationState(
            phase: 'idle', lastSuccess: _noon.subtract(const Duration(minutes: 12))),
        clock: _atNoon,
      ));
      final status = find.text('Synced 12 min ago');
      final action = find.text('Sync now');
      expect(t.getTopLeft(action).dx, greaterThan(t.getTopLeft(status).dx));
      expect((t.getCenter(action).dy - t.getCenter(status).dy).abs(),
          lessThan(12));
    });

    _tw('the panel is no taller than a row (no title, no big button)',
        (t) async {
      await t.pumpWidget(_control(
        SyncPresentationState(
            phase: 'idle', lastSuccess: _noon.subtract(const Duration(minutes: 12))),
        clock: _atNoon,
      ));
      expect(t.getSize(find.byType(SyncControl)).height, lessThan(90));
      for (final old in const [
        'Band sync',
        'Syncing with your band',
        'Sync completed',
        'Local data refreshed. Band not contacted.',
      ]) {
        expect(find.text(old), findsNothing, reason: 'old panel copy "$old"');
      }
    });

    _tw('tapping the action syncs once and does not expand the list',
        (t) async {
      var syncs = 0;
      await t.pumpWidget(_control(
          _failed(reason: 'Band disconnected during sync'),
          onSync: () => syncs++));
      await t.tap(find.text('Retry'));
      await t.pump();
      expect(syncs, 1);
      _expectCollapsed();
    });

    _tw('no action while a sync runs', (t) async {
      var syncs = 0;
      await t.pumpWidget(_control(_withBacklog(), onSync: () => syncs++));
      expect(find.text('Sync now'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(syncs, 0);
    });
  });

  group('tap the line to expand the steps', () {
    _tw('collapsed by default, expands inline, collapses again', (t) async {
      await t.pumpWidget(_control(_withBacklog()));
      _expectCollapsed();
      await t.tap(find.text('Downloading · 2 h 10 min of band time to go'));
      await _settle(t);
      _expectExpanded();
      expect(find.text('12,400 records · 31 chunks'), findsOneWidget,
          reason: 'the banked counts the engine reported');
      await t.tap(find.text('Downloading · 2 h 10 min of band time to go'));
      await _settle(t);
      _expectCollapsed();
    });

    _tw('a failed run: the steps explain it when expanded', (t) async {
      await t.pumpWidget(_control(_failed(reason: 'Band disconnected during sync')));
      _expectCollapsed();
      await t.tap(find.text('Sync failed: Band disconnected during sync'));
      await _settle(t);
      _expectExpanded();
    });

    _tw('open state is remembered across a rebuild (key sync-details)',
        (t) async {
      await t.pumpWidget(_control(_withBacklog(), key: UniqueKey()));
      await t.tap(find.text('Downloading · 2 h 10 min of band time to go'));
      await _settle(t);
      _expectExpanded();
      // Away and back: a brand-new element.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_control(_withBacklog(), key: UniqueKey()));
      await _settle(t);
      _expectExpanded();
      final sp = await SharedPreferences.getInstance();
      expect(sp.getKeys().any((k) => k.contains('sync-details')), isTrue,
          reason: 'persisted under the stable key, with the accordion state');
    });

    _tw('closed state is remembered too', (t) async {
      await t.pumpWidget(_control(_withBacklog(), key: UniqueKey()));
      final line = find.text('Downloading · 2 h 10 min of band time to go');
      await t.tap(line);
      await _settle(t);
      await t.tap(line);
      await _settle(t);
      _expectCollapsed();
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_control(_withBacklog(), key: UniqueKey()));
      await _settle(t);
      _expectCollapsed();
    });
  });

  group('no invention', () {
    _tw('no phase draws a percentage or an estimate', (t) async {
      for (final s in [
        _withBacklog(),
        _noBacklog(),
        _nothingNew(),
        _deriving(const SyncCalculateDetail(dayIndex: 3, dayTotal: 7)),
        _deriving(const SyncCalculateDetail(waiting: true)),
        _failed(reason: 'x'),
        _completed(),
      ]) {
        await t.pumpWidget(_control(s));
        expect(find.textContaining('%'), findsNothing, reason: s.phase);
        expect(find.textContaining('~'), findsNothing, reason: s.phase);
        expect(find.textContaining('estimat'), findsNothing, reason: s.phase);
        expect(find.textContaining('about'), findsNothing, reason: s.phase);
      }
    });
  });

  group('where the line lives', () {
    _tw('the band page uses the one line, not a second panel', (t) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: DeviceDetailView(
          const HealthSource(
            name: 'WHOOP 4.0',
            kind: '',
            tier: SourceTier.wristOptical,
            icon: Icons.watch,
            connected: true,
            isBand: true,
          ),
          syncPresentation: _noBacklog(),
          syncClock: _running,
          onSync: () {},
        ),
      ));
      await t.pump();
      expect(find.byType(SyncControl), findsOneWidget);
      expect(find.text('Downloading…'), findsOneWidget);
      expect(find.text('1:15'), findsOneWidget);
      expect(find.text('Syncing with your band'), findsNothing);
      _expectCollapsed();
    });

    Widget home(AppState app) => MaterialApp(
          theme: buildTheme(Brightness.light),
          home: ChangeNotifierProvider<AppState>.value(
            value: app,
            child: const Scaffold(
                body: HomeScreen(data: HomeData(dayId: '2026-05-20'), hour: 9)),
          ),
        );

    // Oct 4: on Home the line is the greeting header's status line
    // (HomeSyncStatus), and the steps open in a bottom sheet, not inline.
    testWidgets('Home shows the line even when nothing has ever synced',
        (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.pumpWidget(home(app));
      await t.pump();
      expect(find.byType(HomeSyncStatus), findsOneWidget);
      expect(find.byType(SyncControl), findsNothing);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Band sync'), findsNothing);
      expect(find.text('Local data refreshed. Band not contacted.'),
          findsNothing);
      expect(find.text('No band data yet'), findsOneWidget,
          reason: 'one honest sentence for a band that was never synced');
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.textContaining(' ago'), findsNothing,
          reason: 'no last sync, so no time since it');
    });

    testWidgets('Home: a failed sync is the line with Retry; the reason is in '
        'the sheet',
        (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.pumpWidget(home(app));
      await t.pump();
      await t.runAsync(() => app.syncNow());
      await t.pump();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing);
      expect(find.text('Sync failed'), findsOneWidget);
      expect(find.textContaining('Pair a band before syncing'), findsNothing);
      await t.tap(find.text('Show details'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Sync failed: Pair a band before syncing'),
          findsOneWidget);
    });
  });
}
