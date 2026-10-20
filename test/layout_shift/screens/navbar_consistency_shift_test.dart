// Cross-screen consistency for pushed screens: the NavBar's back control and
// title sit in the same place on every screen that uses it. Settled screen vs
// settled screen, restricted to the `shared:` ids. See docs/LAYOUT_SHIFT.md
// "Layout consistency".
//
// Contract: NavBar marks its back control 'shared:navbar-back' and its title
// text 'shared:navbar-title'. Callers add no horizontal padding of their own.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../../support/shift_run.dart';
import '../../support/tabs_consistency_fakes.dart';

const _ids = ['shared:navbar-back', 'shared:navbar-title'];
bool _shared(String id) => id.startsWith('shared:');

class _Repo extends LocalRepository {
  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      const {};
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(ClockFormatController.debugReset);

  final screens = <String, Widget Function()>{
    'settings': () => const MoreSettings(),
    'coach': () => const CoachScreen(),
    'journal': () => const JournalCompose(date: '2026-09-01'),
    'detail': () => Builder(
        builder: (c) => detailScaffold(c, 'Detail', const [Text('body')],
            sub: 'MON 14 AUG')),
  };

  Future<Map<String, Frame>> settled(WidgetTester t) async {
    phoneSurface(t);
    final out = <String, Frame>{};
    for (final e in screens.entries) {
      final app = AppState.forTesting()..repo = _Repo();
      addTearDown(app.dispose);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MultiProvider(providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<UnitsController>(
              create: (_) => UnitsController.seed(UnitSystem.metric)),
          ChangeNotifierProvider<ThemeController>(
              create: (_) => ThemeController.seed(
                  AppThemeChoice.light, Brightness.light)),
          ChangeNotifierProvider<ClockFormatController>(
              create: (_) => ClockFormatController.seed(ClockFormat.h24)),
          ChangeNotifierProvider<LocaleController>(
              create: (_) => LocaleController.seed(null)),
          ChangeNotifierProvider<CoachConfig>(create: (_) => CoachConfig()),
        ], child: e.value()),
      ));
      await t.pump(const Duration(seconds: 3));
      out[e.key] = captureFrame(t);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    }
    return out;
  }

  List<String> unmarked(Map<String, Frame> s) {
    final missing = <String>[];
    for (final e in s.entries) {
      final have = {for (final x in e.value.elements) x.id};
      for (final id in _ids) {
        if (!have.contains(id)) missing.add('${e.key}: $id');
      }
      for (final x in e.value.elements.where((x) => _ids.contains(x.id))) {
        printOnFailure('${e.key} ${x.id} ${x.rect.left},${x.rect.top} ${x.rect.width}x${x.rect.height}');
      }
    }
    return missing;
  }

  testWidgets('every pushed screen marks the NavBar back and title', (t) async {
    final missing = unmarked(await settled(t));
    expect(missing, isEmpty, reason: 'unmarked:\n${missing.join('\n')}');
  });

  testWidgets('NavBar back and title sit in the same place on every screen',
      (t) async {
    final s = await settled(t);
    const p = ShiftPolicy.standard;
    expect(unmarked(s), isEmpty, reason: 'nothing to compare: unmarked');
    final bad = StringBuffer();
    final names = s.keys.toList();
    for (var i = 0; i < names.length; i++) {
      for (var j = i + 1; j < names.length; j++) {
        final r = compareLayouts(s[names[i]]!, s[names[j]]!, p,
            viewport: shiftViewport, only: _shared);
        final name = '${names[i]} vs ${names[j]}';
        printOnFailure(top(name, r));
        if (r.findings.any((f) => f.score >= p.warnAt)) bad.write(worst(name, r, p));
      }
    }
    expect(bad.toString(), isEmpty);
  });

  test('no caller pads a NavBar itself (the inset lives in NavBar)', () {
    final wrap = RegExp(r'Padding\(\s*padding:\s*(const\s+)?EdgeInsets[^(]*\([^)]*\),\s*(//[^\n]*\s*)*child:\s*(const\s+)?NavBar\(');
    final bad = [
      for (final f in Directory('lib/ui2').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart') && wrap.hasMatch(f.readAsStringSync()))
          f.path
    ];
    expect(bad, isEmpty);
  });
}
