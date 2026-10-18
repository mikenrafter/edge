// The Device lab in sub-tabs, like Haptics and Gestures: the tab row sits above
// the list, each tab is a set of collapsible accordions, and both the tab and
// the folded sections are remembered.
//
//   Taps     the note, then ECG on double tap, Touch windows, Repeated double
//            taps (only with FeatureFlag.tapClassifiers)
//   Probes   the hardware probes (only when the screen has a runner)
//   Live     the live devices, no screen of their own (only when given)
//   Logs     Sessions, Step by step, Band events, and the pinned "Save lab log
//            file" button; always offered
//
// The selected tab is kept in Prefs `kDeviceLabTabPref` (an id, never the
// label). A section's fold is kept under accordion_device_lab_*. A tab with
// nothing to show is not offered, and a single tab has no row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart'
    show SettingsAccordion, accordionPrefKey;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_sections.dart' show section;

const _probesMarker = ValueKey('probes-stand-in');
const _liveMarker = ValueKey('live-stand-in');

Finder _tab(String id) => find.byKey(ValueKey('device-lab-tab:$id'));
final _save = find.byKey(const ValueKey('lab-copy-all'));

Widget _lab({
  bool tapTools = true,
  Widget? probes = const SizedBox(key: _probesMarker, height: 40),
  Widget? live = const SizedBox(key: _liveMarker, height: 40),
  LabTab? initialTab,
  List<String> steps = const ['09:15:03.260 | tap +10 ms | last +10 ms | x'],
  List<String> sessions = const ['ECG sensor touches | 3 taps'],
}) =>
    DeviceLabView(
      ecgSupported: true,
      tapTools: tapTools,
      probes: probes,
      live: live,
      initialTab: initialTab,
      steps: steps,
      sessions: sessions,
      onRepeatWindowMs: (_) {},
      onThresholds: (_) {},
    );

Future<void> _pump(WidgetTester t, Widget w,
    {double width = 390, double scale = 1}) async {
  t.view.physicalSize = Size(width * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: w),
  ));
  await t.pumpAndSettle();
}

Future<void> _select(WidgetTester t, String id) async {
  if (_tab(id).evaluate().isEmpty) {
    await t.scrollUntilVisible(_tab(id), 100,
        scrollable: find.descendant(
                of: find.byType(SubTabs), matching: find.byType(Scrollable))
            .first);
  }
  await t.ensureVisible(_tab(id));
  await t.tap(_tab(id));
  await t.pumpAndSettle();
}

SubTabs _tabs(WidgetTester t) => t.widget<SubTabs>(find.byType(SubTabs));

/// Let the repository's write/read queue drain, then settle the frame.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

Finder _header(String title) => find.descendant(
    of: section(title), matching: find.byType(Pressable)).first;

bool _isOpen(WidgetTester t, String title) {
  final a = t.widget<SettingsAccordion>(section(title));
  return find
      .descendant(of: section(title), matching: find.byWidget(a.children.first))
      .evaluate()
      .isNotEmpty;
}

HardwareProbeRunner _runner() => HardwareProbeRunner(
      lab: DeviceLabLog(),
      sendBuzz: (onReply) async {
        onReply('pending', 40);
        return true;
      },
      sendPattern: (effects, loop, onReply) async {
        onReply('pending', 40);
        return true;
      },
      isConnected: () => true,
      ecgSupported: () => true,
      ecgBusy: () => false,
      beginEcg: () async => false,
      endEcg: () async {},
      isEcgAlive: () => false,
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
  });

  group('the tabs offered', () {
    testWidgets('Taps, Probes, Live, Logs, in that order, on Taps first',
        (t) async {
      await _pump(t, _lab());
      // Motion sits between Probes and Live when the screen has a recorder;
      // this lab has none (see device_lab_motion_test.dart).
      expect([for (final x in LabTab.values) x.id],
          ['taps', 'probes', 'motion', 'live', 'logs']);
      expect(_tabs(t).items, ['Taps', 'Probes', 'Live', 'Logs']);
      expect(_tabs(t).index, 0);
      expect(find.text('ECG on double tap'), findsOneWidget);
      expect(find.byKey(_probesMarker), findsNothing);
      expect(find.byKey(_liveMarker), findsNothing);
      expect(find.text('Band events'), findsNothing);
    });

    testWidgets('each tab shows only its own sections', (t) async {
      await _pump(t, _lab());
      await _select(t, 'probes');
      expect(find.byKey(_probesMarker), findsOneWidget);
      expect(find.text('ECG on double tap'), findsNothing);
      await _select(t, 'live');
      expect(find.byKey(_liveMarker), findsOneWidget);
      expect(find.byKey(_probesMarker), findsNothing);
      await _select(t, 'logs');
      expect(find.text('Band events'), findsOneWidget);
      expect(find.text('Step by step'), findsOneWidget);
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.byKey(_liveMarker), findsNothing);
      await _select(t, 'taps');
      expect(find.text('Touch windows'), findsOneWidget);
      expect(find.text('Repeated double taps'), findsOneWidget);
      expect(find.text('Band events'), findsNothing);
    });

    testWidgets('the save button is the logs tab\'s alone', (t) async {
      await _pump(t, _lab());
      expect(_save, findsNothing);
      await _select(t, 'probes');
      expect(_save, findsNothing);
      await _select(t, 'logs');
      expect(_save, findsOneWidget);
    });

    testWidgets('without the tap tools the Taps tab is gone', (t) async {
      await _pump(t, _lab(tapTools: false));
      expect(_tabs(t).items, ['Probes', 'Live', 'Logs']);
      expect(_tab('taps'), findsNothing);
      expect(find.byKey(_probesMarker), findsOneWidget);
      expect(find.text('ECG on double tap'), findsNothing);
    });

    testWidgets('Probes and Live appear only when the screen has them',
        (t) async {
      await _pump(t, _lab(probes: null, live: null));
      expect(_tabs(t).items, ['Taps', 'Logs']);
      await _pump(t, _lab(probes: null));
      expect(_tabs(t).items, ['Taps', 'Live', 'Logs']);
    });

    testWidgets('one tab left has no row, only the logs', (t) async {
      await _pump(t, _lab(tapTools: false, probes: null, live: null));
      expect(find.byType(SubTabs), findsNothing);
      expect(find.text('Band events'), findsOneWidget);
      expect(_save, findsOneWidget);
    });
  });

  group('the selected tab is remembered', () {
    testWidgets('choosing a tab stores its id, and the next visit opens on it',
        (t) async {
      await _pump(t, _lab());
      await _select(t, 'live');
      expect(Prefs.getString(kDeviceLabTabPref, ''), 'live',
          reason: 'an id, not the label');
      expect(kDeviceLabTabPref, 'ui.device_lab_tab');
      await t.pumpWidget(const SizedBox());
      await _pump(t, _lab());
      expect(_tabs(t).index, 2);
      expect(find.byKey(_liveMarker), findsOneWidget);
    });

    testWidgets('a first visit, or an unreadable stored id, opens on the '
        'first tab, and looking is not a write', (t) async {
      await _pump(t, _lab());
      expect(_tabs(t).index, 0);
      expect(Prefs.getString(kDeviceLabTabPref, ''), '');
      await t.pumpWidget(const SizedBox());
      Prefs.setString(kDeviceLabTabPref, 'gone');
      await _pump(t, _lab());
      expect(_tabs(t).index, 0);
    });

    testWidgets('a remembered tab that is not offered shows the first, and '
        'the memory is left alone', (t) async {
      Prefs.setString(kDeviceLabTabPref, 'taps');
      await _pump(t, _lab(tapTools: false));
      expect(_tabs(t).index, 0);
      expect(_tabs(t).items.first, 'Probes');
      expect(Prefs.getString(kDeviceLabTabPref, ''), 'taps');
    });

    testWidgets('initialTab opens that tab over the remembered one',
        (t) async {
      Prefs.setString(kDeviceLabTabPref, 'live');
      await _pump(t, _lab(initialTab: LabTab.logs));
      expect(_tabs(t).index, 3);
      expect(find.text('Band events'), findsOneWidget);
      expect(Prefs.getString(kDeviceLabTabPref, ''), 'live');
    });
  });

  group('the accordions are remembered', () {
    testWidgets('every section starts open and looking writes nothing',
        (t) async {
      await _pump(t, _lab());
      for (final s in const [
        'ECG on double tap',
        'Touch windows',
        'Repeated double taps',
      ]) {
        expect(_isOpen(t, s), isTrue, reason: s);
      }
      await _select(t, 'logs');
      for (final s in const ['Sessions', 'Step by step', 'Band events']) {
        expect(_isOpen(t, s), isTrue, reason: s);
      }
      expect((await SharedPreferences.getInstance())
          .getKeys()
          .where((k) => k.startsWith('accordion_')), isEmpty);
    });

    testWidgets('folding a section stores it under its own id, and it comes '
        'back folded while the others stay open', (t) async {
      await _pump(t, _lab());
      await t.tap(_header('Touch windows'));
      await _settle(t);
      expect(_isOpen(t, 'Touch windows'), isFalse);
      expect(Prefs.getBool(accordionPrefKey('device_lab_touch_windows'), true),
          isFalse);
      await t.pumpWidget(const SizedBox());
      await _settle(t);
      await _pump(t, _lab());
      await _settle(t);
      expect(_isOpen(t, 'Touch windows'), isFalse);
      expect(_isOpen(t, 'ECG on double tap'), isTrue);
      expect(_isOpen(t, 'Repeated double taps'), isTrue);
    });

    testWidgets('a section folded on Logs stays folded after a tab change '
        'and a return', (t) async {
      await _pump(t, _lab(initialTab: LabTab.logs));
      await t.tap(_header('Step by step'));
      await _settle(t);
      expect(_isOpen(t, 'Step by step'), isFalse);
      await _select(t, 'taps');
      await _select(t, 'logs');
      await _settle(t);
      expect(_isOpen(t, 'Step by step'), isFalse);
      expect(_isOpen(t, 'Band events'), isTrue);
    });

    testWidgets('every section has its own id', (t) async {
      await _pump(t, _lab());
      final ids = <String?>[];
      for (final tab in const ['taps', 'logs']) {
        await _select(t, tab);
        ids.addAll([
          for (final a in t.widgetList<SettingsAccordion>(
              find.byType(SettingsAccordion)))
            a.id,
        ]);
      }
      expect(ids, everyElement(isNotNull));
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, everyElement(startsWith('device_lab_')));
    });

    testWidgets('a folded log section still says what is inside it',
        (t) async {
      await _pump(t, _lab(initialTab: LabTab.logs));
      await t.tap(_header('Step by step'));
      await _settle(t);
      expect(find.text('1 step'), findsOneWidget);
    });
  });

  group('the hardware probes in their tab', () {
    testWidgets('folding the section does not hide Stop, and leaving the tab '
        'ends a running probe', (t) async {
      final r = _runner();
      await _pump(
          t,
          _lab(
              probes: HardwareProbePanel(runner: r, logText: () => ''),
              initialTab: LabTab.probes));
      await t.tap(find.byKey(const ValueKey('probe-buzz')));
      await t.pump();
      expect(r.running, ProbeKind.buzz);
      await t.tap(_header('Hardware probes'));
      await _settle(t);
      expect(_isOpen(t, 'Hardware probes'), isFalse);
      expect(find.byKey(const ValueKey('probe-stop')), findsOneWidget);
      expect(r.running, ProbeKind.buzz, reason: 'folding is not leaving');
      await _select(t, 'logs');
      await t.pump(const Duration(seconds: 10));
      expect(r.running, isNull);
    });
  });

  group('layout', () {
    testWidgets('360 pt at 1.3x text, every tab: no overflow, every tab '
        'reachable', (t) async {
      await _pump(t, _lab(probes: HardwareProbePanel(
              runner: _runner(), logText: () => '')),
          width: 360, scale: 1.3);
      for (final id in const ['taps', 'probes', 'live', 'logs', 'taps']) {
        await _select(t, id);
        expect(t.takeException(), isNull, reason: id);
        expect(_tabs(t).index,
            _tabs(t).items.indexOf(LabTab.values.firstWhere((x) => x.id == id).label),
            reason: id);
      }
      await _select(t, 'logs');
      expect(_save.hitTestable(), findsOneWidget);
    });
  });
}
