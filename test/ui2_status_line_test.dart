// StatusLine: the fixed-height line under every tab title. First that applies:
// import > derive running > sync running > "Synced through ...". The height is
// the same in every case at every text scale, so a progress tick moves nothing.
// No real clock: the sync sentence and the idle day come from the test.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/shared_slot.dart';
import 'package:openstrap_edge/ui2/status_line.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'support/shift_run.dart';
import 'support/tabs_consistency_fakes.dart' show captureFrame;

final _t0 = DateTime(2026, 10, 4, 12);

class _App extends AppState {
  _App(this.pres, {this.at}) : super.forTesting();
  SyncPresentationState pres;
  final DateTime? at;
  final derive = ValueNotifier<DeriveProgress?>(null);

  @override
  SyncPresentationState get syncPresentation => pres;
  @override
  DateTime? get lastRecordAt => at;
  @override
  ValueListenable<DeriveProgress?> get deriveProgress => derive;
}

const _syncing = SyncPresentationState(
    phase: 'downloading', busy: true, contactedBand: true);

Widget _host(AppState? app, {double scale = 1}) {
  Widget body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    StatusLine(todayId: '2026-10-04', now: _t0),
    const SharedSlot('below', child: SizedBox(height: 40)),
  ]);
  if (app != null) {
    body = ChangeNotifierProvider<AppState>.value(value: app, child: body);
  }
  return MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: body),
    ),
  );
}

String _text(WidgetTester t) => t
    .widget<Text>(find.descendant(
        of: find.byType(StatusLine), matching: find.byType(Text)))
    .data!;

void main() {
  testWidgets('idle: synced through, same-day clock only', (t) async {
    final app = _App(const SyncPresentationState(), at: DateTime(2026, 10, 4, 11, 6));
    addTearDown(app.dispose);
    await t.pumpWidget(_host(app));
    expect(_text(t), startsWith('Synced through '));
    expect(_text(t), contains('11:06'));
  });

  testWidgets('sync running: the headline, no backlog detail', (t) async {
    final app = _App(_syncing);
    addTearDown(app.dispose);
    await t.pumpWidget(_host(app));
    expect(_text(t), 'Downloading…');
  });

  testWidgets('derive running beats sync', (t) async {
    final app = _App(_syncing);
    addTearDown(app.dispose);
    app.derive.value = const DeriveProgress(dayIndex: 3, dayTotal: 12);
    await t.pumpWidget(_host(app));
    expect(_text(t), 'Calculating · day 3 of 12');
  });

  testWidgets('import beats derive; copying shows stage and step', (t) async {
    final app = _App(_syncing);
    addTearDown(app.dispose);
    app.derive.value = const DeriveProgress(dayIndex: 3, dayTotal: 12);
    app.importProgress.value =
        const ImportCopying(ImportStage.heartRate, 10, 100, 4, 9);
    await t.pumpWidget(_host(app));
    expect(_text(t), 'Importing · Copying heart rate · step 4 of 9');
  });

  testWidgets('import preparing and rebuilding', (t) async {
    final app = _App(const SyncPresentationState());
    addTearDown(app.dispose);
    app.importProgress.value = const ImportPreparing(ImportPrepStep.inflating);
    await t.pumpWidget(_host(app));
    expect(_text(t), 'Importing · Unpacking the backup');
    app.importProgress.value = const ImportRebuilding(2, 9, null);
    await t.pump();
    expect(_text(t), 'Recalculating · day 2 of 9');
  });

  testWidgets('import done falls through to the next source', (t) async {
    final app = _App(_syncing);
    addTearDown(app.dispose);
    app.importProgress.value = const ImportDone();
    await t.pumpWidget(_host(app));
    expect(_text(t), 'Downloading…');
  });

  testWidgets('no AppState: empty line at the same height', (t) async {
    await t.pumpWidget(_host(null));
    final bare = t.getSize(find.byType(StatusLine)).height;
    final app = _App(_syncing);
    addTearDown(app.dispose);
    await t.pumpWidget(_host(app));
    expect(t.getSize(find.byType(StatusLine)).height, bare);
    await t.pumpWidget(_host(null));
    expect(find.descendant(of: find.byType(StatusLine), matching: find.byType(Text)),
        findsNothing);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('same height in every case at ${scale}x', (t) async {
      final long = ImportCopying(ImportStage.archive, 1, 2, 8, 9);
      final heights = <double>{};
      Future<void> measure(AppState? a) async {
        await t.pumpWidget(_host(a, scale: scale));
        heights.add(t.getSize(find.byType(StatusLine)).height);
      }

      await measure(null);
      final idle = _App(const SyncPresentationState(), at: _t0);
      final sync = _App(_syncing);
      final der = _App(_syncing)..derive.value = const DeriveProgress(waiting: true);
      final imp = _App(_syncing)..importProgress.value = long;
      for (final a in [idle, sync, der, imp]) {
        addTearDown(a.dispose);
        await measure(a);
      }
      expect(heights.length, 1, reason: '$heights');
    });
  }

  testWidgets('a progress tick changes no rect', (t) async {
    phoneSurface(t);
    final app = _App(_syncing);
    addTearDown(app.dispose);
    app.importProgress.value = const ImportCopying(ImportStage.sleep, 1, 9, 1, 9);
    await t.pumpWidget(_host(app));
    final before = captureFrame(t);
    app.importProgress.value =
        const ImportCopying(ImportStage.heartRate, 5000, 9000, 4, 9);
    await t.pump();
    app.importProgress.value = const ImportRebuilding(7, 212, '2026-03-01');
    await t.pump();
    final after = captureFrame(t);
    final ids = {for (final e in after.elements) e.id};
    expect(ids, containsAll(['shared:status-line', 'shared:below']));
    final r = compareLayouts(before, after, ShiftPolicy.standard,
        viewport: shiftViewport, only: (id) => id.startsWith('shared:'));
    expect(r.findings, isEmpty);
  });
}
