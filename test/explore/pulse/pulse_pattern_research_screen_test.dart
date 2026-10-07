// The developer-only research screen and its entry.
//
// The view reads existing detector output. It must not look like a breathing
// metric: two permanent lines, "not analysed" instead of 0, no count on an
// excluded night, and no clinical or severity vocabulary anywhere on screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/explore/pulse/pulse_pattern_night.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_research_screen.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/theme.dart' show buildTheme;

const String _title = 'Repeating nighttime pulse patterns (research)';
const String _disclaimer =
    'Research view. Not a breathing measurement, not a screening and not a '
    'diagnosis. The band has no airflow or oxygen sensor.';
const String _zeroLine =
    'Zero patterns means zero under this detector on the analysed data. It '
    'does not mean breathing was normal.';

/// Words that must never appear on this screen, in any state.
final RegExp _banned = RegExp(
  r'\b(apnea|apnoea|ahi|hypopnea|hypopnoea|desaturations?|spo2|spo₂|'
  r'oxygen dips?|mild|moderate|severe|severity|'
  r'disturbed breathing minutes)\b',
  caseSensitive: false,
);

// The detector's own note uses words the screen must not repeat.
const String _bannedNote =
    'CVHR/ACAT (Hayano) apnea SCREEN — NOT a diagnosis, NOT an AHI; '
    'single-night CVHR has substantial night-to-night variability';

const _admitted = PulsePatternNight(
  dayId: '2026-10-05',
  analysedHours: 6.3,
  coverage: 0.92,
  cycleCount: 23,
  cyclesPerHour: 23 / 6.3,
  detectorNote: _bannedNote,
);
const _zero = PulsePatternNight(
  dayId: '2026-10-04',
  analysedHours: 5.5,
  coverage: 0.90,
  cycleCount: 0,
  cyclesPerHour: 0,
);
const _unanalysed = PulsePatternNight(
  dayId: '2026-10-03',
  exclusions: ['not analysed'],
  detectorNote: 'too few beats for a CVHR screen (need ≥60)',
);
// The model still carries 41 (parsed as stored); the screen must not show it.
const _excluded = PulsePatternNight(
  dayId: '2026-10-02',
  analysedHours: 3.2,
  coverage: 0.55,
  cycleCount: 41,
  cyclesPerHour: 41 / 3.2,
  exclusions: ['under 4 analysed hours', 'coverage under 80%'],
  detectorNote: _bannedNote,
);

Capabilities _caps({bool devMode = false}) =>
    Capabilities(CapabilityInputs.detached(devMode: devMode));

Future<void> _pump(WidgetTester t, Widget home, {Capabilities? caps}) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(Provider<Capabilities>.value(
    value: caps ?? _caps(),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: home),
  ));
  await t.pump();
}

Future<void> _pumpScreen(WidgetTester t, List<PulsePatternNight> nights) =>
    _pump(t, PulsePatternResearchScreen(nights: nights));

/// Every piece of rendered text, whitespace-collapsed, offstage included.
List<String> _texts(WidgetTester t) => [
      for (final w in t.widgetList<RichText>(
          find.byType(RichText, skipOffstage: false)))
        w.text.toPlainText().replaceAll(RegExp(r'\s+'), ' ').trim(),
    ];

String _all(WidgetTester t) => _texts(t).join('\n');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setBool(Prefs.explorePulsePatterns, false);
  });
  tearDown(() => Prefs.setBool(Prefs.explorePulsePatterns, false));

  group('the banned-word scan', () {
    test('catches what it is meant to catch', () {
      for (final s in [
        'Sleep apnea screen',
        'apnoea',
        'AHI 12',
        'hypopnea count',
        'desaturation burden',
        'SpO2 dip',
        'an oxygen dip',
        'mild',
        'Moderate',
        'SEVERE',
        'severity',
        'disturbed breathing minutes',
      ]) {
        expect(_banned.hasMatch(s), isTrue, reason: s);
      }
    });

    test('lets the required lines through', () {
      expect(_banned.hasMatch(_disclaimer), isFalse);
      expect(_banned.hasMatch(_zeroLine), isFalse);
      expect(_banned.hasMatch(_title), isFalse);
    });
  });

  group('PulsePatternResearchScreen', () {
    testWidgets('shows the title', (t) async {
      await _pumpScreen(t, [_admitted]);
      expect(find.text(_title), findsWidgets);
    });

    testWidgets('both permanent lines are present, word for word', (t) async {
      await _pumpScreen(t, [_admitted, _zero, _unanalysed, _excluded]);
      expect(_texts(t), contains(_disclaimer));
      expect(_texts(t), contains(_zeroLine));
    });

    testWidgets('the permanent lines are there with no nights at all',
        (t) async {
      await _pumpScreen(t, const []);
      expect(_texts(t), contains(_disclaimer));
      expect(_texts(t), contains(_zeroLine));
    });

    testWidgets('the permanent lines cannot be dismissed', (t) async {
      await _pumpScreen(t, [_admitted, _zero]);
      expect(find.byType(Dismissible, skipOffstage: false), findsNothing);
      expect(find.byType(MaterialBanner, skipOffstage: false), findsNothing);
      expect(find.byType(SnackBar, skipOffstage: false), findsNothing);
      expect(find.byIcon(Icons.close, skipOffstage: false), findsNothing);
      // Tapping the lines and the page does nothing to them.
      await t.tap(find.text(_disclaimer), warnIfMissed: false);
      await t.pump();
      expect(_texts(t), contains(_disclaimer));
      expect(_texts(t), contains(_zeroLine));
    });

    testWidgets('an analysed night shows hours, coverage and the count',
        (t) async {
      await _pumpScreen(t, [_admitted]);
      final all = _all(t);
      expect(all, contains('2026-10-05'));
      expect(all, contains('6.3'), reason: 'analysed hours');
      expect(all, contains('92%'), reason: 'coverage');
      expect(RegExp(r'\b23\b').hasMatch(all), isTrue, reason: 'cycle count');
      expect(all, isNot(contains('not analysed')));
    });

    testWidgets('a zero-cycle analysed night shows 0 and is not "not analysed"',
        (t) async {
      await _pumpScreen(t, [_zero]);
      final all = _all(t);
      expect(all, contains('5.5'));
      expect(all, contains('90%'));
      expect(RegExp(r'\b0\b').hasMatch(all), isTrue, reason: 'the zero count');
      expect(all, isNot(contains('not analysed')));
    });

    testWidgets('an unanalysed night says "not analysed" and shows no 0',
        (t) async {
      await _pumpScreen(t, [_unanalysed]);
      final all = _all(t);
      expect(all, contains('2026-10-03'));
      expect(all, contains('not analysed'));
      expect(RegExp(r'\b0\b').hasMatch(all), isFalse,
          reason: 'absent must never render as a count of 0');
    });

    testWidgets('an excluded night shows its exclusions in words and no count',
        (t) async {
      await _pumpScreen(t, [_excluded]);
      final all = _all(t);
      expect(all, contains('2026-10-02'));
      expect(all, contains('under 4 analysed hours'));
      expect(all, contains('coverage under 80%'));
      expect(RegExp(r'\b41\b').hasMatch(all), isFalse,
          reason: 'the detector count of an excluded night is not shown');
      expect(all, isNot(contains('not analysed')),
          reason: 'it was analysed; it is excluded, which is different');
    });

    testWidgets('each state is told apart when shown together', (t) async {
      await _pumpScreen(t, [_admitted, _zero, _unanalysed, _excluded]);
      final all = _all(t);
      expect(all, contains('not analysed'));
      expect(all, contains('under 4 analysed hours'));
      expect(RegExp(r'\b23\b').hasMatch(all), isTrue);
      expect(RegExp(r'\b41\b').hasMatch(all), isFalse);
    });

    testWidgets('evidence links: Hayano 2011 and Berry 2012 on doi.org',
        (t) async {
      await _pumpScreen(t, [_admitted]);
      final all = _all(t);
      expect(all, contains('Hayano'));
      expect(all, contains('2011'));
      expect(all, contains('doi.org/10.1161/CIRCEP.110.958009'));
      expect(all, contains('Berry'));
      expect(all, contains('2012'));
      expect(all, contains('doi.org/10.5664/jcsm.2172'));
    });

    final states = <String, List<PulsePatternNight>>{
      'no nights': const [],
      'analysed': [_admitted],
      'zero cycles': [_zero],
      'not analysed': [_unanalysed],
      'excluded': [_excluded],
      'all four together': [_admitted, _zero, _unanalysed, _excluded],
    };
    for (final e in states.entries) {
      testWidgets('no banned wording on screen: ${e.key}', (t) async {
        await _pumpScreen(t, e.value);
        for (final s in _texts(t)) {
          expect(_banned.hasMatch(s), isFalse,
              reason: 'banned word in on-screen text: "$s"');
        }
      });
    }

    testWidgets('the detector note is stored but its wording is never shown',
        (t) async {
      await _pumpScreen(t, [_admitted, _excluded]);
      final all = _all(t);
      expect(all, isNot(contains('single-night')));
      expect(all, isNot(contains('NOT an AHI')));
    });
  });

  group('PulsePatternResearchEntry gating', () {
    Future<void> pumpEntry(WidgetTester t,
        {required bool devMode, required bool pref}) async {
      Prefs.setBool(Prefs.explorePulsePatterns, pref);
      await _pump(
        t,
        Scaffold(body: PulsePatternResearchEntry(nights: [_admitted])),
        caps: _caps(devMode: devMode),
      );
    }

    testWidgets('developer mode AND the pref: shown', (t) async {
      await pumpEntry(t, devMode: true, pref: true);
      expect(find.text(_title), findsOneWidget);
    });

    testWidgets('developer mode, pref off (the default): not there',
        (t) async {
      expect(Prefs.getBool(Prefs.explorePulsePatterns, false), isFalse,
          reason: 'default off');
      await pumpEntry(t, devMode: true, pref: false);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('pref on without developer mode: not there', (t) async {
      await pumpEntry(t, devMode: false, pref: true);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('neither: not there', (t) async {
      await pumpEntry(t, devMode: false, pref: false);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('tapping the shown entry opens the research screen',
        (t) async {
      await pumpEntry(t, devMode: true, pref: true);
      await t.tap(find.text(_title));
      await t.pumpAndSettle();
      expect(find.byType(PulsePatternResearchScreen), findsOneWidget);
      expect(_texts(t), contains(_disclaimer));
    });

    testWidgets('the shown entry carries no banned wording', (t) async {
      await pumpEntry(t, devMode: true, pref: true);
      for (final s in _texts(t)) {
        expect(_banned.hasMatch(s), isFalse, reason: '"$s"');
      }
    });
  });
}
