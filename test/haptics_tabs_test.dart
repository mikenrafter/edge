// Haptics in sub-tabs (Oct 4): the screen was one long page of accordions; it
// is now the app's SubTabs row with one tab per concern, each showing only its
// own groups.
//
//   Patterns  Your patterns, Presets                       (two accordions)
//   Alerts    Alerts, Apps and automation slots             (two accordions)
//   Activity  the workout slots                             (one group: no
//                                                            accordion, a card)
//   Cues      Gestures, Breathing slots                     (two accordions)
//   Band      Safety, Test, Calibration (developer mode)    (accordions)
//
// A section's link to the screen where its slots are set sits at the bottom of
// its tab, as a plain text link (no hairline beside it). The selected tab is
// remembered (Prefs `kHapticsTabPref`, an id, never the label); a caller can
// open one directly (`HapticsSettingsView.initialTab`, `HapticsSettings.tab`).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/haptics_screen_support.dart';
import 'support/dart_source_lexical.dart';
import 'support/settings_sections.dart';

final _mine = userPattern('a', 'Morning nudge');
final _preset = presetPattern('sys.p1', 'One pulse', 'preset.one_pulse');

const _labels = ['Patterns', 'Alerts', 'Activity', 'Cues', 'Band'];
const _ids = ['patterns', 'alerts', 'activity', 'cues', 'band'];

/// Which slot sections each tab lists.
const _sectionsOf = {
  'alerts': ['alerts', 'apps'],
  'activity': ['activity'],
  'cues': ['gestures', 'breathing'],
};

Iterable<String> _slotKeys(Iterable<String> sections) => [
      for (final s in kHapticSlotSections)
        if (sections.contains(s.id)) for (final k in s.slots) k.key,
    ];

final _allSlotKeys = _slotKeys([for (final s in kHapticSlotSections) s.id]);

Finder _tab(String id) => find.byKey(ValueKey('haptics-tab:$id'));
Finder _slot(String key) => find.byKey(ValueKey('haptic-slot:$key'));
Finder _link(String id) => find.byKey(ValueKey('haptic-slot-section-link:$id'));

Future<void> _go(WidgetTester t, String id) => openHapticsTab(t, id);

// A tab the row has not scrolled to yet is not built.
Future<void> _reach(WidgetTester t, String id) async {
  for (var i = 0; i < 6 && _tab(id).evaluate().isEmpty; i++) {
    await t.drag(find.byType(SubTabs), const Offset(-200, 0));
    await t.pumpAndSettle();
  }
}

Future<void> _pump(
  WidgetTester t, {
  HubCalls? calls,
  bool devMode = false,
  HapticsTab? initialTab,
}) async {
  final c = calls ?? HubCalls();
  await pumpTall(
    t,
    initialTab == null
        ? hubView(c, patterns: [_mine, _preset], profile: kMg, devMode: devMode)
        : HapticsSettingsView(
            initialTab: initialTab,
            patterns: [_mine, _preset],
            usageOf: (_) => 0,
            profile: kMg,
            allowLong: false,
            devMode: devMode,
            commandsLeft: 30,
            queued: 0,
            bandConnected: true,
            onPlay: (s) async => true,
            onBuzz: () {},
            onAllowLong: (_) {},
            onAdd: (n, s) {},
            onReplace: (id, s) {},
            onRename: (id, n) {},
            onDelete: (_) {},
            onDeviceLab: () {},
            slotPatternName: (_) => 'Two pulses',
            onOpenSlotScreen: c.openedSections.add,
            onAssignToSlot: (k, p) {},
          ),
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() => Prefs.setString(kHapticsTabPref, ''));

  group('the tab row', () {
    testWidgets('is the app\'s SubTabs under the nav bar, five short tabs, '
        'Patterns selected first', (t) async {
      await _pump(t);
      final tabs = t.widget<SubTabs>(find.byType(SubTabs));
      expect(tabs.items, _labels);
      expect(tabs.index, 0);
      expect([for (final k in tabs.itemKeys!) (k as ValueKey).value],
          [for (final id in _ids) 'haptics-tab:$id']);
      expect(_tab('patterns'), findsOneWidget);
      expect(t.getTopLeft(find.byType(SubTabs)).dy,
          greaterThan(t.getBottomLeft(find.byType(NavBar)).dy - 1));
      // Nothing else in the page is above the rows but the tabs.
      expect(find.byType(SubTabs), findsOneWidget);
    });

    testWidgets('tapping a tab selects it', (t) async {
      await _pump(t);
      await _go(t, 'alerts');
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 1);
      await _go(t, 'band');
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 4);
    });
  });

  group('each tab shows its own section and not the others\'', () {
    testWidgets('Patterns: the saved patterns, the presets, and the two ways '
        'to make one; no slots, no safety', (t) async {
      await _pump(t);
      expect(sectionTitles(t), ['Your patterns', 'Presets']);
      expect(find.byKey(const ValueKey('haptic-pattern:a')), findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-pattern:sys.p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('haptics-new-taps')), findsOneWidget);
      expect(find.byKey(const ValueKey('haptics-new-notes')), findsOneWidget);
      for (final k in _allSlotKeys) {
        expect(_slot(k), findsNothing, reason: k);
      }
      expect(find.byKey(const ValueKey('haptics-allow-long')), findsNothing);
      expect(find.byKey(const ValueKey('haptics-buzz')), findsNothing);
    });

    for (final e in _sectionsOf.entries) {
      testWidgets('${e.key}: exactly its slots (${e.value.join(', ')})',
          (t) async {
        await _pump(t);
        await _go(t, e.key);
        final mine = _slotKeys(e.value).toSet();
        for (final k in _allSlotKeys) {
          expect(_slot(k), mine.contains(k) ? findsOneWidget : findsNothing,
              reason: '${e.key}: $k');
        }
        expect(find.byKey(const ValueKey('haptic-pattern:a')), findsNothing);
        expect(find.byKey(const ValueKey('haptics-allow-long')), findsNothing);
        expect(find.byKey(const ValueKey('haptics-buzz')), findsNothing);
        // Only this tab's links.
        for (final s in kHapticSlotSections) {
          expect(_link(s.id),
              e.value.contains(s.id) ? findsOneWidget : findsNothing,
              reason: '${e.key}: link ${s.id}');
        }
      });
    }

    testWidgets('Band: Safety and Test, and Calibration in developer mode '
        'only', (t) async {
      await _pump(t);
      await _go(t, 'band');
      expect(sectionTitles(t), ['Safety', 'Test']);
      expect(find.byKey(const ValueKey('haptics-allow-long')), findsOneWidget);
      expect(find.textContaining('band commands left'), findsOneWidget);
      expect(find.textContaining('Queue:'), findsOneWidget);
      expect(find.byKey(const ValueKey('haptics-buzz')), findsOneWidget);
      expect(find.byKey(const ValueKey('haptics-device-lab')), findsNothing);
      for (final k in _allSlotKeys) {
        expect(_slot(k), findsNothing, reason: k);
      }
      await _pump(t, devMode: true);
      await _go(t, 'band');
      expect(sectionTitles(t), ['Safety', 'Test', 'Calibration']);
      expect(find.byKey(const ValueKey('haptics-device-lab')), findsOneWidget);
    });

    testWidgets('a tab with several groups folds them in accordions; the one '
        'with a single group (Activity) has none', (t) async {
      await _pump(t);
      await _go(t, 'alerts');
      expect(sectionTitles(t), ['Alerts', 'Apps and automation']);
      await _go(t, 'activity');
      expect(sectionTitles(t), isEmpty);
      await _go(t, 'cues');
      expect(sectionTitles(t), ['Gestures', 'Breathing']);
      // Never an accordion inside an accordion.
      expect(
          find.descendant(
              of: find.byType(SettingsAccordion),
              matching: find.byType(SettingsAccordion)),
          findsNothing);
    });

    testWidgets('the accordion ids are stable and per group', (t) async {
      await _pump(t);
      await _go(t, 'cues');
      expect([for (final a in accordions(t)) a.id],
          ['haptics_slots_gestures', 'haptics_slots_breathing']);
    });
  });

  group('nothing was lost: every control is reachable in some tab', () {
    testWidgets('every slot of every section is on exactly one tab',
        (t) async {
      await _pump(t);
      final seen = <String, int>{};
      for (final id in _ids) {
        await _go(t, id);
        for (final k in _allSlotKeys) {
          if (_slot(k).evaluate().isNotEmpty) seen[k] = (seen[k] ?? 0) + 1;
        }
      }
      expect(seen.keys.toSet(), _allSlotKeys.toSet());
      expect(seen.values, everyElement(1));
      expect(_allSlotKeys, contains('breath.inhale'));
      expect(_allSlotKeys, contains('alert.relay'));
    });

    testWidgets('a slot row still opens the picker, and a pattern still '
        'goes onto it', (t) async {
      final c = HubCalls();
      await _pump(t, calls: c);
      await _go(t, 'cues');
      await t.tap(_slot('breath.inhale'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pattern-picker-row:a')));
      await t.pumpAndSettle();
      expect(c.assigned, [('breath.inhale', 'a')]);
    });

    testWidgets('a pattern\'s "Use on a slot" sheet still lists every slot',
        (t) async {
      await _pump(t);
      await t.tap(find.byKey(const ValueKey('haptic-pattern:a')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('haptic-action-assign')));
      await t.pumpAndSettle();
      for (final k in _allSlotKeys) {
        expect(find.byKey(ValueKey('haptic-assign-slot:$k')), findsOneWidget,
            reason: k);
      }
    });
  });

  group('links at the bottom of their tab', () {
    for (final e in _sectionsOf.entries) {
      testWidgets('${e.key}: one link per section, below every row of the '
          'tab', (t) async {
        final c = HubCalls();
        await _pump(t, calls: c);
        await _go(t, e.key);
        final lastRow = [
          for (final k in _slotKeys(e.value)) t.getBottomLeft(_slot(k)).dy,
        ].reduce((a, b) => a > b ? a : b);
        for (final s in e.value) {
          expect(t.getTopLeft(_link(s)).dy, greaterThan(lastRow),
              reason: '${e.key}: link $s is not at the bottom');
        }
        // Their order is the sections' order.
        final ys = [for (final s in e.value) t.getTopLeft(_link(s)).dy];
        expect(ys, [...ys]..sort());
        for (final s in e.value) {
          await t.tap(_link(s));
          await t.pumpAndSettle();
        }
        expect(c.openedSections, e.value);
      });
    }

    testWidgets('a link is a text link: no hairline or separator below the '
        'first of them', (t) async {
      await _pump(t);
      for (final id in ['alerts', 'activity', 'cues']) {
        await _go(t, id);
        final firstLink =
            t.getTopLeft(_link(_sectionsOf[id]!.first)).dy;
        for (final d in t.widgetList<Divider>(find.byType(Divider))) {
          expect(
              t.getTopLeft(find.byWidget(d)).dy, lessThan(firstLink),
              reason: '$id: a divider sits at or below the links');
        }
      }
      expect(withKeyPrefix(t, 'haptic-slot-sep:'), isEmpty);
      expect(withKeyPrefix(t, 'haptic-slot-section:'), isEmpty,
          reason: 'the old in-list section headers are gone');
    });

    testWidgets('without onOpenSlotScreen there are no links', (t) async {
      await pumpTall(
        t,
        HapticsSettingsView(
          initialTab: HapticsTab.alerts,
          patterns: const [],
          usageOf: (_) => 0,
          profile: null,
          allowLong: false,
          devMode: false,
          commandsLeft: 30,
          queued: 0,
          bandConnected: true,
          onPlay: (s) async => true,
          onBuzz: () {},
          onAllowLong: (_) {},
          onAdd: (n, s) {},
          onReplace: (id, s) {},
          onRename: (id, n) {},
          onDelete: (_) {},
          onDeviceLab: () {},
        ),
      );
      expect(_link('alerts'), findsNothing);
      expect(_slot('alert.water'), findsOneWidget);
    });
  });

  group('the selected tab is remembered', () {
    testWidgets('choosing a tab stores its id, and the next visit opens on it',
        (t) async {
      await _pump(t);
      await _go(t, 'cues');
      expect(Prefs.getString(kHapticsTabPref, ''), 'cues',
          reason: 'an id, not the label');
      await t.pumpWidget(const SizedBox());
      await _pump(t);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 3);
      expect(_slot('breath.inhale'), findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-pattern:a')), findsNothing);
    });

    testWidgets('a first visit, or an unreadable stored id, opens on Patterns',
        (t) async {
      Prefs.setString(kHapticsTabPref, 'gone');
      await _pump(t);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 0);
    });

    testWidgets('looking is not a write', (t) async {
      await _pump(t);
      expect(Prefs.getString(kHapticsTabPref, ''), '');
    });
  });

  group('a caller can open one tab', () {
    testWidgets('initialTab opens that tab, over the remembered one',
        (t) async {
      Prefs.setString(kHapticsTabPref, 'activity');
      for (final tab in HapticsTab.values) {
        await _pump(t, initialTab: tab);
        expect(t.widget<SubTabs>(find.byType(SubTabs)).index, tab.index,
            reason: tab.id);
        await t.pumpWidget(const SizedBox());
      }
      await _pump(t, initialTab: HapticsTab.cues);
      expect(_slot('gesture.start'), findsOneWidget);
      expect(_slot('alert.water'), findsNothing);
    });

    test('the route hands its tab to the view, and ids are the stored form',
        () {
      final src = File('lib/ui2/profile/haptics_settings.dart')
          .readAsStringSync();
      expect(codeOnly(bodyOf(src, 'class _HapticsSettingsState')),
          contains('initialTab: widget.tab'));
      expect([for (final x in HapticsTab.values) x.id], _ids);
      expect([for (final x in HapticsTab.values) x.label], _labels);
    });
  });

  group('360 pt wide at 1.3x text', () {
    for (final id in _ids) {
      testWidgets('$id tab lays out without overflow', (t) async {
        t.view.physicalSize = const Size(360, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final tab = HapticsTab.values.firstWhere((x) => x.id == id);
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: HapticsSettingsView(
            initialTab: tab,
            patterns: [_mine, _preset],
            usageOf: (_) => 0,
            profile: kMg,
            allowLong: false,
            devMode: true,
            commandsLeft: 30,
            queued: 0,
            bandConnected: true,
            onPlay: (s) async => true,
            onBuzz: () {},
            onAllowLong: (_) {},
            onAdd: (n, s) {},
            onReplace: (id, s) {},
            onRename: (id, n) {},
            onDelete: (_) {},
            onDeviceLab: () {},
            slotPatternName: (_) => 'Two pulses',
            onOpenSlotScreen: (_) {},
            onAssignToSlot: (k, p) {},
          ),
        ));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        // The tab row still reaches the last tab by scrolling.
        await _reach(t, 'band');
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }
  });
}
