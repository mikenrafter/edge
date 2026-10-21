// The three-row header block (shared:header-rows) sits in the same place on
// all four tab roots, and nothing moves when a sync starts or ends: row
// heights are fixed, so the status sentence swaps text inside its box.
// Contract: docs/LAYOUT_SHIFT.md "Layout consistency"; content test is
// test/ui2_header_rows_all_tabs_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/header_rows_fakes.dart';
import '../../support/shift_run.dart';
import '../../support/tabs_consistency_fakes.dart';

const _id = 'shared:header-rows';
const _tabs = [
  ShellDomain.today,
  ShellDomain.sleep,
  ShellDomain.activity,
  ShellDomain.health,
];

ShiftRect? _rect(Frame f, String id) {
  for (final e in f.elements) {
    if (e.id == id) return e.rect;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  HeaderApp makeApp() => HeaderApp(pres: headerIdle(), through: headerEdge)
    ..repo = TabsRepo(homeBundle(
        readiness: 70,
        overnightAt: todayAtMs(8, 42),
        activityAt: todayAtMs(8, 42)));

  testWidgets('shared:header-rows has the same rect on all four tabs',
      (t) async {
    phoneSurface(t);
    final app = makeApp();
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app));
    await settleShell(t);
    final rects = <String, ShiftRect?>{};
    rects[ShellDomain.today.label] = _rect(captureFrame(t), _id);
    for (final d in _tabs.skip(1)) {
      await goTab(t, d);
      rects[d.label] = _rect(captureFrame(t), _id);
    }
    printOnFailure(rects.toString());
    for (final e in rects.entries) {
      expect(e.value, isNotNull, reason: '${e.key} lacks $_id');
    }
    final home = rects[ShellDomain.today.label]!;
    for (final e in rects.entries) {
      expect(e.value, home, reason: '${e.key} rect differs from Today');
    }
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('shared:header-rows is below the title and above the content',
      (t) async {
    phoneSurface(t);
    final app = makeApp();
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app));
    await settleShell(t);
    final f = captureFrame(t);
    final rows = _rect(f, _id);
    final title = _rect(f, 'shared:title');
    expect(rows, isNotNull, reason: 'no $_id on Today');
    expect(title, isNotNull);
    expect(rows!.top, greaterThanOrEqualTo((title!.top + title.height)));
    expect(rows.height, greaterThan(0));
    await t.pump(const Duration(seconds: 5));
  });

  for (final d in _tabs) {
    testWidgets('${d.label}: idle -> syncing -> idle moves nothing', (t) async {
      phoneSurface(t);
      final app = makeApp();
      addTearDown(app.dispose);
      await t.pumpWidget(shellApp(app));
      await settleShell(t);
      if (d != ShellDomain.today) await goTab(t, d);
      final idle = captureFrame(t);
      const p = ShiftPolicy.standard;
      bool mine(String id) => id.startsWith('shared:');
      expect(_rect(idle, _id), isNotNull, reason: '${d.label} lacks $_id');

      app.setPres(headerSyncing());
      await t.pump(const Duration(seconds: 1));
      final syncing = captureFrame(t);
      expect(_rect(syncing, _id), _rect(idle, _id),
          reason: 'block rect changed when the sync started');
      final r1 = compareLayouts(idle, syncing, p,
          viewport: shiftViewport, only: mine);
      expect(r1.findings.any((f) => f.score >= p.warnAt), isFalse,
          reason: worst('${d.label} idle vs syncing', r1, p));

      app.setPres(headerIdle());
      await t.pump(const Duration(seconds: 1));
      final after = captureFrame(t);
      expect(_rect(after, _id), _rect(idle, _id),
          reason: 'block rect changed when the sync ended');
      final r2 = compareLayouts(idle, after, p,
          viewport: shiftViewport, only: mine);
      expect(r2.findings.any((f) => f.score >= p.warnAt), isFalse,
          reason: worst('${d.label} idle vs after', r2, p));
      await t.pump(const Duration(seconds: 5));
    });
  }
}
