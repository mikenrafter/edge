// Tab roots on a tablet: content is capped at 600 pt and centred, the header
// (title, avatar, status line) stays inside the same column, and on a phone
// nothing moves. Probed with the same `shared:` ids the tabs-consistency test
// uses, on the real shell with its real four tabs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/bundled_fonts.dart';
import '../../support/tabs_consistency_fakes.dart';

const _maxW = 600.0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await loadFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Map<ShellDomain, Frame>> tabs(WidgetTester t, double w, double h) async {
    t.view.physicalSize = Size(w, h);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = AppState.forTesting()
      ..repo = TabsRepo(homeBundle(
          readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app));
    await settleShell(t);
    final vp = ShiftRect(0, 0, w, h);
    final out = <ShellDomain, Frame>{ShellDomain.today: captureFrame(t, viewport: vp)};
    for (final d in [ShellDomain.sleep, ShellDomain.activity, ShellDomain.health]) {
      await goTab(t, d);
      out[d] = captureFrame(t, viewport: vp);
    }
    await t.pump(const Duration(seconds: 5));
    return out;
  }

  ShiftRect rectOf(Frame f, String id, String tab) {
    final m = f.elements.where((e) => e.id == id);
    expect(m, isNotEmpty, reason: '$tab lacks $id');
    return m.first.rect;
  }

  testWidgets('820 pt: content-top is at most 600 wide and centred on all 4 tabs',
      (t) async {
    final all = await tabs(t, 820, 1180);
    final bad = StringBuffer();
    for (final e in all.entries) {
      final r = rectOf(e.value, 'shared:content-top', e.key.label);
      final cx = r.left + r.width / 2;
      if (r.width > _maxW + 0.5 || (cx - 410).abs() > 1) {
        bad.writeln('${e.key.label}: content-top left=${r.left} '
            'width=${r.width} centre=$cx (want width <= $_maxW, centre 410)');
      }
    }
    expect(bad.toString(), isEmpty, reason: bad.toString());
  });

  testWidgets('820 pt: title, avatar and status line stay inside the capped column',
      (t) async {
    final all = await tabs(t, 820, 1180);
    final bad = StringBuffer();
    for (final e in all.entries) {
      final col = rectOf(e.value, 'shared:content-top', e.key.label);
      if (col.width > _maxW + 0.5) {
        bad.writeln('${e.key.label}: column is ${col.width} wide, not capped');
      }
      for (final id in ['shared:title', 'shared:avatar', 'shared:status-line']) {
        final r = rectOf(e.value, id, e.key.label);
        if (r.left < col.left - 0.5 || r.left + r.width > col.left + col.width + 0.5) {
          bad.writeln('${e.key.label}: $id spans ${r.left}..${r.left + r.width}, '
              'column is ${col.left}..${col.left + col.width}');
        }
      }
    }
    expect(bad.toString(), isEmpty, reason: bad.toString());
  });

  testWidgets('390 pt: header and content-top rects are unchanged', (t) async {
    final all = await tabs(t, 390, 844);
    for (final e in all.entries) {
      final n = e.key.label;
      final title = rectOf(e.value, 'shared:title', n);
      final avatar = rectOf(e.value, 'shared:avatar', n);
      final top = rectOf(e.value, 'shared:content-top', n);
      expect([title.left, title.top], [20, 13], reason: '$n title');
      expect([avatar.left, avatar.top], [326, 8], reason: '$n avatar');
      expect(top.top, 64, reason: '$n content-top y');
      expect(top.left, 16, reason: '$n content-top x');
      expect(top.width, 358, reason: '$n content-top width');
    }
  });

  // The scroll viewport is full width; only the content is capped. A drag that
  // starts in the empty gutter still scrolls, and Home and Sleep still pull to
  // refresh from it. 700 pt tall so every root has scroll extent.
  Future<void> shell(WidgetTester t) async {
    t.view.physicalSize = const Size(820, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = AppState.forTesting()
      ..repo = TabsRepo(homeBundle(
          readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app));
    await settleShell(t);
  }

  ScrollableState rootScroll(WidgetTester t) {
    final list = find.byType(ListView).hitTestable().first;
    return t.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first);
  }

  testWidgets('820 pt: a vertical drag starting in the gutter scrolls all 4 tabs',
      (t) async {
    await shell(t);
    const gutter = Offset(60, 450); // left of the 110..710 content column
    for (final d in [
      ShellDomain.today,
      ShellDomain.sleep,
      ShellDomain.activity,
      ShellDomain.health
    ]) {
      await goTab(t, d);
      final sc = rootScroll(t);
      expect(sc.position.maxScrollExtent, greaterThan(0),
          reason: '${d.label}: fixture has nothing to scroll');
      final before = sc.position.pixels;
      await t.dragFrom(gutter, const Offset(0, -300));
      await t.pump(const Duration(milliseconds: 400));
      expect(sc.position.pixels, greaterThan(before),
          reason: '${d.label}: drag in the gutter did not scroll');
    }
    await t.pump(const Duration(seconds: 5));
  });

  for (final d in [ShellDomain.today, ShellDomain.sleep]) {
    testWidgets('820 pt: a pull starting in the gutter refreshes ${d.label}',
        (t) async {
      await shell(t);
      await goTab(t, d);
      expect(find.byType(RefreshIndicator).hitTestable(), findsOneWidget,
          reason: '${d.label} has a pull-to-refresh');
      await t.dragFrom(const Offset(60, 200), const Offset(0, 400));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget,
          reason: 'a pull from the gutter must trigger the refresh');
      await t.pump(const Duration(seconds: 5));
    });
  }
}
