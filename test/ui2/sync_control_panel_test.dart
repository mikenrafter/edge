// 8M — the sync control is a status panel, not a spinner: a step list with
// each step's state and time, live counts, a ticking elapsed time while busy,
// and Retry after a failure. No percentage is ever drawn: the band does not
// say how much it holds, so there is nothing true to divide by.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _t0 = DateTime(2026, 10, 2, 9);

SyncStep _step(
  SyncStepId id,
  SyncStepStatus status, {
  DateTime? start,
  DateTime? end,
  String? note,
  SyncDownloadDetail? download,
  SyncCalculateDetail? calculate,
}) => SyncStep(
  id: id,
  status: status,
  startedAt: start,
  endedAt: end,
  note: note,
  download: download,
  calculate: calculate,
);

SyncPresentationState _downloading({SyncDownloadDetail? detail}) =>
    SyncPresentationState(
      phase: 'downloading',
      busy: true,
      contactedBand: true,
      startedAt: _t0,
      steps: [
        _step(
          SyncStepId.connect,
          SyncStepStatus.done,
          start: _t0,
          end: _t0.add(const Duration(seconds: 2)),
        ),
        _step(
          SyncStepId.download,
          SyncStepStatus.running,
          start: _t0.add(const Duration(seconds: 2)),
          download:
              detail ??
              SyncDownloadDetail(
                records: 12400,
                chunks: 31,
                syncedThrough: DateTime(2026, 10, 1, 22, 15),
                bandNewest: DateTime(2026, 10, 2, 8, 45),
              ),
        ),
        _step(SyncStepId.calculate, SyncStepStatus.waiting),
        _step(SyncStepId.done, SyncStepStatus.waiting),
      ],
    );

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  theme: buildTheme(Brightness.light),
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: c!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('idle: one Sync now and nothing else claiming activity', (
    t,
  ) async {
    var taps = 0;
    await t.pumpWidget(
      _host(
        SyncControl(
          state: const SyncPresentationState(),
          onSync: () => taps++,
          clock: () => _t0,
        ),
      ),
    );
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Connect'), findsNothing);
    await t.tap(find.text('Sync now'));
    expect(taps, 1);
  });

  testWidgets('running: the four steps, their states and the live counts', (
    t,
  ) async {
    await t.pumpWidget(
      _host(
        SyncControl(
          state: _downloading(),
          onSync: () {},
          clock: () => _t0.add(const Duration(seconds: 75)),
        ),
      ),
    );
    for (final label in ['Connect', 'Download', 'Calculate', 'Done']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.textContaining('12,400 records'), findsOneWidget);
    expect(find.textContaining('31 chunks'), findsOneWidget);
    expect(find.textContaining('Synced through'), findsOneWidget);
    // The band reported its newest record, so a backlog is a fact: 10 h 30 m.
    expect(find.textContaining('10 h 30 m'), findsOneWidget);
    // Connect finished in 2 s.
    expect(find.text('2 s'), findsOneWidget);
    // Total elapsed.
    expect(find.text('1:15'), findsOneWidget);
    // Waiting steps are labelled as waiting, not left blank.
    expect(find.text('Waiting'), findsNWidgets(2));
    // Busy: the button is present but inert.
    expect(find.text('Sync now'), findsOneWidget);
  });

  testWidgets('never draws a percentage or a made-up total', (t) async {
    await t.pumpWidget(
      _host(
        SyncControl(
          state: _downloading(
            detail: const SyncDownloadDetail(records: 800, chunks: 2),
          ),
          onSync: () {},
          clock: () => _t0.add(const Duration(seconds: 5)),
        ),
      ),
    );
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('backlog'), findsNothing);
    expect(find.textContaining('800 records'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('elapsed time ticks while busy', (t) async {
    var now = _t0.add(const Duration(seconds: 10));
    await t.pumpWidget(
      _host(
        SyncControl(state: _downloading(), onSync: () {}, clock: () => now),
      ),
    );
    expect(find.text('0:10'), findsOneWidget);
    now = now.add(const Duration(seconds: 1));
    await t.pump(Motion.tick);
    expect(find.text('0:11'), findsOneWidget);
    now = now.add(const Duration(seconds: 1));
    await t.pump(Motion.tick);
    expect(find.text('0:12'), findsOneWidget);
  });

  testWidgets('calculate: day i of n with the day, then waiting', (t) async {
    SyncPresentationState calc(SyncCalculateDetail d) => SyncPresentationState(
      phase: 'deriving',
      busy: true,
      contactedBand: true,
      startedAt: _t0,
      steps: [
        _step(
          SyncStepId.connect,
          SyncStepStatus.skipped,
          note: 'Already connected',
        ),
        _step(
          SyncStepId.download,
          SyncStepStatus.done,
          start: _t0,
          end: _t0.add(const Duration(seconds: 30)),
          download: const SyncDownloadDetail(records: 900, chunks: 3),
        ),
        _step(
          SyncStepId.calculate,
          SyncStepStatus.running,
          start: _t0.add(const Duration(seconds: 30)),
          calculate: d,
        ),
        _step(SyncStepId.done, SyncStepStatus.waiting),
      ],
    );
    DateTime clock() => _t0.add(const Duration(seconds: 40));
    await t.pumpWidget(
      _host(
        SyncControl(
          state: calc(
            const SyncCalculateDetail(
              dayIndex: 2,
              dayTotal: 5,
              day: '2026-10-01',
            ),
          ),
          onSync: () {},
          clock: clock,
        ),
      ),
    );
    expect(find.textContaining('Day 2 of 5'), findsOneWidget);
    expect(find.textContaining('2026-10-01'), findsOneWidget);
    expect(find.text('Already connected'), findsOneWidget);

    await t.pumpWidget(
      _host(
        SyncControl(
          state: calc(const SyncCalculateDetail(waiting: true)),
          onSync: () {},
          clock: clock,
        ),
      ),
    );
    expect(
      find.textContaining('Waiting for another calculation to finish'),
      findsOneWidget,
    );
    expect(find.textContaining('Day '), findsNothing);
  });

  testWidgets('failure: the reason in words and a Retry that syncs again', (
    t,
  ) async {
    var taps = 0;
    final failed = SyncPresentationState(
      phase: 'failed',
      error: 'Bad state: Could not connect to the band',
      failureReason: 'Could not connect to the band',
      startedAt: _t0,
      finishedAt: _t0.add(const Duration(seconds: 8)),
      steps: [
        _step(
          SyncStepId.connect,
          SyncStepStatus.failed,
          start: _t0,
          end: _t0.add(const Duration(seconds: 8)),
        ),
        _step(SyncStepId.download, SyncStepStatus.skipped),
        _step(SyncStepId.calculate, SyncStepStatus.skipped),
        _step(SyncStepId.done, SyncStepStatus.skipped),
      ],
    );
    await t.pumpWidget(
      _host(
        SyncControl(
          state: failed,
          onSync: () => taps++,
          clock: () => _t0.add(const Duration(hours: 3)),
        ),
      ),
    );
    expect(find.textContaining('Could not connect to the band'), findsWidgets);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
    // Frozen at the moment it failed, not the three hours since.
    expect(find.text('0:08'), findsOneWidget);
    await t.tap(find.text('Retry'));
    expect(taps, 1);
  });

  testWidgets('a busy control ignores a second tap', (t) async {
    var taps = 0;
    await t.pumpWidget(
      _host(
        SyncControl(
          state: _downloading(),
          onSync: () => taps++,
          clock: () => _t0,
        ),
      ),
    );
    await t.tap(find.text('Sync now'));
    expect(taps, 0);
  });

  testWidgets('completed: every step done, last success shown', (t) async {
    final done = SyncPresentationState(
      phase: 'completed',
      contactedBand: true,
      lastSuccess: _t0.add(const Duration(seconds: 20)),
      startedAt: _t0,
      finishedAt: _t0.add(const Duration(seconds: 20)),
      steps: [
        for (final id in SyncStepId.values)
          _step(
            id,
            SyncStepStatus.done,
            start: _t0,
            end: _t0.add(const Duration(seconds: 5)),
          ),
      ],
    );
    await t.pumpWidget(
      _host(SyncControl(state: done, onSync: () {}, clock: () => _t0)),
    );
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.textContaining('Last successful sync'), findsOneWidget);
  });

  testWidgets('partial: download note, calculate done, Done (partial)', (
    t,
  ) async {
    final state = SyncPresentationState(
      phase: 'completed',
      contactedBand: true,
      partial: true,
      lastSuccess: _t0.add(const Duration(seconds: 20)),
      startedAt: _t0,
      finishedAt: _t0.add(const Duration(seconds: 20)),
      steps: [
        _step(
          SyncStepId.connect,
          SyncStepStatus.skipped,
          note: 'Already connected',
        ),
        _step(
          SyncStepId.download,
          SyncStepStatus.done,
          start: _t0,
          end: _t0.add(const Duration(seconds: 12)),
          note: 'More remains on the band — sync again to continue',
          download: const SyncDownloadDetail(records: 900, chunks: 3),
        ),
        _step(
          SyncStepId.calculate,
          SyncStepStatus.done,
          start: _t0,
          end: _t0.add(const Duration(seconds: 5)),
        ),
        _step(
          SyncStepId.done,
          SyncStepStatus.done,
          start: _t0,
          end: _t0,
          note: 'Done (partial)',
        ),
      ],
    );
    await t.pumpWidget(
      _host(SyncControl(state: state, onSync: () {}, clock: () => _t0)),
    );
    expect(find.text('Sync partly completed'), findsOneWidget);
    expect(
      find.text('More remains on the band — sync again to continue'),
      findsOneWidget,
    );
    expect(find.text('Done (partial)'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
  });

  testWidgets('calculate with nothing new reads skipped — nothing new', (
    t,
  ) async {
    final state = SyncPresentationState(
      phase: 'completed',
      contactedBand: true,
      startedAt: _t0,
      finishedAt: _t0.add(const Duration(seconds: 8)),
      steps: [
        _step(
          SyncStepId.connect,
          SyncStepStatus.skipped,
          note: 'Already connected',
        ),
        _step(
          SyncStepId.download,
          SyncStepStatus.done,
          start: _t0,
          end: _t0.add(const Duration(seconds: 8)),
        ),
        _step(
          SyncStepId.calculate,
          SyncStepStatus.skipped,
          note: kCalculateSkippedNote,
        ),
        _step(SyncStepId.done, SyncStepStatus.done, start: _t0, end: _t0),
      ],
    );
    await t.pumpWidget(
      _host(SyncControl(state: state, onSync: () {}, clock: () => _t0)),
    );
    expect(find.text('Skipped — nothing new'), findsOneWidget);
  });

  testWidgets('calculate shows day 0 of N before the first day ends', (
    t,
  ) async {
    final state = SyncPresentationState(
      phase: 'deriving',
      busy: true,
      contactedBand: true,
      startedAt: _t0,
      steps: [
        _step(SyncStepId.connect, SyncStepStatus.skipped),
        _step(SyncStepId.download, SyncStepStatus.done, start: _t0, end: _t0),
        _step(
          SyncStepId.calculate,
          SyncStepStatus.running,
          start: _t0,
          calculate: const SyncCalculateDetail(dayIndex: 0, dayTotal: 3),
        ),
        _step(SyncStepId.done, SyncStepStatus.waiting),
      ],
    );
    await t.pumpWidget(
      _host(SyncControl(state: state, onSync: () {}, clock: () => _t0)),
    );
    expect(find.text('Day 0 of 3'), findsOneWidget);
  });

  testWidgets('3.1x text scale does not overflow', (t) async {
    await t.pumpWidget(
      _host(
        SyncControl(
          state: _downloading(),
          onSync: () {},
          clock: () => _t0.add(const Duration(minutes: 12, seconds: 9)),
        ),
        scale: 3.1,
      ),
    );
    expect(t.takeException(), isNull);
  });
}
