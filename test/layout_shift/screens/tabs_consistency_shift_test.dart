// Cross-tab consistency: the same shared control sits in the same place on
// every tab (title, avatar, first content). Settled tab vs settled tab,
// restricted to the `shared:` ids. See docs/LAYOUT_SHIFT.md "Layout consistency".
//
// Contract for the green phase: ScreenTitle's title text = 'shared:title',
// ProfileAvatar = 'shared:avatar', the first content element under the header
// (or sub-tabs) = 'shared:content-top', the tab bar = 'shared:tabbar'.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';
import '../../support/tabs_consistency_fakes.dart';

const _ids = ['shared:title', 'shared:avatar', 'shared:content-top'];
bool _shared(String id) => id.startsWith('shared:');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Map<ShellDomain, Frame>> settledTabs(WidgetTester t) async {
    phoneSurface(t);
    final app = AppState.forTesting()
      ..repo = TabsRepo(homeBundle(
          readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app));
    await settleShell(t);
    final out = <ShellDomain, Frame>{ShellDomain.today: captureFrame(t)};
    for (final d in [ShellDomain.sleep, ShellDomain.activity, ShellDomain.health]) {
      await goTab(t, d);
      out[d] = captureFrame(t);
    }
    // Every IndexedStack child is built now; drain timers.
    await t.pump(const Duration(seconds: 5));
    return out;
  }

  List<String> unmarked(Map<ShellDomain, Frame> tabs) {
    final missing = <String>[];
    for (final e in tabs.entries) {
      final have = {for (final x in e.value.elements) x.id};
      for (final id in _ids) {
        if (!have.contains(id)) missing.add('${e.key.label}: $id');
      }
    }
    for (final e in tabs.entries) {
      printOnFailure('${e.key.label}: ${e.value.elements.length} elements');
    }
    return missing;
  }

  testWidgets('every tab marks title, avatar and first content', (t) async {
    final missing = unmarked(await settledTabs(t));
    expect(missing, isEmpty, reason: 'unmarked shared elements:\n${missing.join('\n')}');
  });

  testWidgets('shared elements sit in the same place on every tab', (t) async {
    final tabs = await settledTabs(t);
    const p = ShiftPolicy.standard;
    // An empty `shared:` set would make every comparison vacuously pass.
    expect(unmarked(tabs), isEmpty, reason: 'nothing to compare: unmarked');
    final bad = StringBuffer();
    final doms = tabs.keys.toList();
    for (var i = 0; i < doms.length; i++) {
      for (var j = i + 1; j < doms.length; j++) {
        final r = compareLayouts(tabs[doms[i]]!, tabs[doms[j]]!, p,
            viewport: shiftViewport, only: _shared);
        final name = '${doms[i].label} vs ${doms[j].label}';
        printOnFailure(top(name, r));
        if (r.findings.any((f) => f.score >= p.warnAt)) bad.write(worst(name, r, p));
      }
    }
    expect(bad.toString(), isEmpty);
  });
}
