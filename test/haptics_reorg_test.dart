// RED tests for the owner-approved haptics page reorganisation (2026-10-08;
// /home/mini/Documents/repos/edge.research/plan-remaining-babeltele.md,
// "OWNER ANSWERS" Q1). Numbers in the group names are the owner's answers:
//   1 slot rows: mini staff + per-slot preview
//   2 presets live in their section's accordion, not on the Patterns tab
//   3 assigning a preset needs a confirmation
//   4 "Play example sequence" on Gestures, ECG, Breathing, Alarm snooze
//   5 "Also play vibrations on the phone" (Settings tab) + phone fallback
//   6 the Band tab is now Settings
//   7 the vocabulary probe is always an item in Settings
//
// New API is reached by key / name (see support/haptics_reorg_support.dart).
// New ARB keys will be needed for every new English string asserted below.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/haptic_score.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/haptics_reorg_support.dart';
import 'support/haptics_screen_support.dart';
import 'support/settings_sections.dart';

Finder _slot(String k) => find.byKey(ValueKey('haptic-slot:$k'));
Finder _k(String k) => find.byKey(ValueKey(k));

final _gPreset = presetPattern('sys.g', 'Gesture start default', 'gesture.start');
final _aPreset = presetPattern('sys.a', 'Water default', 'alert.water');
final _zPreset = presetPattern('sys.z', 'Zone default', 'alert.zone');
final _general = presetPattern('sys.p1', 'One pulse', 'preset.one_pulse');
final _mine = userPattern('a', 'Morning nudge');
final _all = [_mine, _general, _gPreset, _aPreset, _zPreset];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() => Prefs.setString(kHapticsTabPref, ''));

  group('1. slot rows show a mini staff and a per-slot preview', () {
    for (final tab in ['alerts', 'activity', 'cues']) {
      testWidgets('$tab: every slot row has a HapticScore of its pattern next '
          'to its name', (t) async {
        await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
        await openHapticsTab(t, tab);
        final rows = withKeyPrefix(t, 'haptic-slot:')
            .map((w) => (w.key as ValueKey<String>).value.substring(12))
            .toList();
        expect(rows, isNotEmpty);
        for (final k in rows) {
          final staff = _k('haptic-slot-staff:$k');
          expect(staff, findsOneWidget, reason: k);
          final score = find.descendant(
              of: staff, matching: find.byType(HapticScore));
          expect(score, findsOneWidget, reason: k);
          expect(t.widget<HapticScore>(score).pattern.patternId, k);
          // Same row: the staff overlaps the slot row vertically.
          final r = t.getRect(_slot(k)), s = t.getRect(staff);
          expect(s.top < r.bottom && s.bottom > r.top, isTrue,
              reason: '$k: staff is not on the slot row');
          expect(find.descendant(of: _slot(k), matching: find.text('Two pulses')),
              findsOneWidget,
              reason: '$k: the pattern name stays');
        }
      });
    }

    testWidgets('the preview button plays that slot\'s pattern and does not '
        'open the picker', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'alerts');
      await t.tap(_k('haptic-slot-preview:alert.water'));
      await t.pumpAndSettle();
      expect([for (final s in c.played) s.patternId], ['alert.water']);
      expect(_k('pattern-picker'), findsNothing);
    });

    testWidgets('every slot of every section has a preview button',
        (t) async {
      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      for (final tab in ['alerts', 'activity', 'cues']) {
        await openHapticsTab(t, tab);
        for (final k in withKeyPrefix(t, 'haptic-slot:')
            .map((w) => (w.key as ValueKey<String>).value.substring(12))) {
          expect(_k('haptic-slot-preview:$k'), findsOneWidget, reason: k);
        }
      }
    });
  });

  group('2. presets live in their section\'s accordion', () {
    testWidgets('the Patterns tab keeps Your patterns (and General) and no '
        'slot-section preset groups', (t) async {
      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      final ids = [for (final a in accordions(t)) a.id];
      expect(ids, contains('haptics_your_patterns'));
      for (final id in ids) {
        expect(id, isNot(matches(r'^haptics_presets_(?!general$)')),
            reason: 'a slot-section preset group is still on Patterns');
      }
      expect(_k('haptic-pattern:a'), findsOneWidget);
      expect(withKeyPrefix(t, 'haptic-preset:'), isEmpty);
    });

    for (final e in {
      'cues': ('haptics_slots_gestures', 'sys.g'),
      'alerts': ('haptics_slots_alerts', 'sys.a'),
      'activity': ('haptics_slots_activity', 'sys.z'),
    }.entries) {
      testWidgets('${e.key}: the section\'s preset ${e.value.$2} is a row in '
          'its accordion', (t) async {
        await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
        await openHapticsTab(t, e.key);
        final row = _k('haptic-preset:${e.value.$2}');
        if (e.key == 'activity') {
          // One group: the tab has no accordion today (haptics_tabs_test); a
          // card or an accordion are both fine, but the row is on this tab.
          expect(row, findsOneWidget);
          return;
        }
        final acc = find.byWidgetPredicate(
            (w) => w is SettingsAccordion && w.id == e.value.$1,
            description: e.value.$1);
        expect(acc, findsOneWidget);
        expect(find.descendant(of: acc, matching: row), findsOneWidget);
      });
    }

    testWidgets('a preset of another section is not in this one',
        (t) async {
      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      await openHapticsTab(t, 'alerts');
      expect(_k('haptic-preset:sys.g'), findsNothing);
      expect(_k('haptic-preset:sys.z'), findsNothing);
    });
  });

  group('3. assigning a preset needs a confirmation', () {
    testWidgets('tap shows a dialog; cancel assigns nothing', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-preset:sys.g'));
      await t.pumpAndSettle();
      expect(_k('haptic-preset-confirm'), findsOneWidget);
      expect(find.descendant(
              of: _k('haptic-preset-confirm'),
              matching: find.textContaining('Gesture start default')),
          findsWidgets);
      expect(c.assigned, isEmpty, reason: 'assigned before confirming');
      await t.tap(find.descendant(
          of: _k('haptic-preset-confirm'), matching: find.text('Cancel')));
      await t.pumpAndSettle();
      expect(_k('haptic-preset-confirm'), findsNothing);
      expect(c.assigned, isEmpty);
      expect(c.storeUntouched, isTrue);
    });

    testWidgets('confirm assigns the preset to its slot', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-preset:sys.g'));
      await t.pumpAndSettle();
      await t.tap(_k('haptic-preset-confirm-ok'));
      await t.pumpAndSettle();
      expect(c.assigned, [('gesture.start', 'sys.g')]);
      expect(c.storeUntouched, isTrue);
    });
  });

  // slot sections with an example, and what they must play.
  const sections = ['gestures', 'ecg', 'breathing', 'alarm'];

  group('4. Play example sequence', () {
    testWidgets('only Gestures, ECG, Breathing and Alarm snooze have it; at '
        'the top of the accordion, with a visible buzz-limit note',
        (t) async {
      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      for (final tab in ['alerts', 'activity', 'cues']) {
        await openHapticsTab(t, tab);
        final got = withKeyPrefix(t, 'haptic-example-play:')
            .map((w) => (w.key as ValueKey<String>).value.substring(20))
            .toSet();
        expect(got, tab == 'cues' ? sections.toSet() : isEmpty, reason: tab);
      }
      await openHapticsTab(t, 'cues');
      for (final s in sections) {
        final play = _k('haptic-example-play:$s');
        expect(find.descendant(of: play, matching: find.text('Play example sequence')),
            findsOneWidget, reason: s);
        final first = _slot(slotKeysOf(s).first);
        expect(t.getTopLeft(play).dy, lessThan(t.getTopLeft(first).dy),
            reason: '$s: not above the first slot');
        final note = _k('haptic-example-note:$s');
        expect(note, findsOneWidget, reason: s);
        expect(find.descendant(of: note, matching: find.textContaining('buzz limit')),
            findsOneWidget, reason: s);
        expect(_k('haptic-example-stop:$s'), findsNothing, reason: s);
      }
    });

    testWidgets('Gestures: start, follow-up, then confirmed; and a separate '
        'start, follow-up, failed', (t) async {
      final clock = FakeExampleClock();
      await pumpReorg(t, ReorgCalls(),
          clock: clock, patterns: _all, profile: kMg, commandsLeft: 0);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:gestures'));
      await t.pump();
      await clock.drain(t);
      final runs = _runs(clock.played, 'gesture.start');
      expect(runs, hasLength(2));
      for (final r in runs) {
        expect(r.take(2), ['gesture.start', 'gesture.followUp']);
        expect(r, hasLength(3));
      }
      expect({for (final r in runs) r[2]},
          {'gesture.confirm', 'gesture.failed'});
    });

    testWidgets('ECG: started, then complete; and started, inconclusive, '
        'try again', (t) async {
      final clock = FakeExampleClock();
      await pumpReorg(t, ReorgCalls(),
          clock: clock, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:ecg'));
      await t.pump();
      await clock.drain(t);
      final runs = _runs(clock.played, 'ecg.started');
      expect(runs.length, greaterThanOrEqualTo(2));
      expect(runs.any((r) => r.contains('ecg.complete')), isTrue);
      final inc = runs.where((r) => r.contains('ecg.inconclusive')).toList();
      expect(inc, isNotEmpty);
      for (final r in inc) {
        final i = r.indexOf('ecg.inconclusive');
        expect(r.length > i + 1 ? r[i + 1] : null, 'ecg.inconclusiveRetry');
        expect(r.contains('ecg.complete'), isFalse,
            reason: 'branches are separate examples');
      }
    });

    testWidgets('Breathing: inhale, hold, exhale, hold', (t) async {
      final clock = FakeExampleClock();
      await pumpReorg(t, ReorgCalls(),
          clock: clock, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:breathing'));
      await t.pump();
      await clock.drain(t);
      expect(clock.played.take(4),
          ['breath.inhale', 'breath.hold', 'breath.exhale', 'breath.hold']);
    });

    testWidgets('Alarm snooze: plays only its own slots', (t) async {
      final clock = FakeExampleClock();
      await pumpReorg(t, ReorgCalls(),
          clock: clock, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:alarm'));
      await t.pump();
      await clock.drain(t);
      expect(clock.played, isNotEmpty);
      expect(slotKeysOf('alarm'), containsAll(clock.played.toSet()));
    });

    for (final s in sections) {
      testWidgets('$s: gaps are real waits, the playing row is highlighted '
          'one at a time, the limit and the band queue are not used',
          (t) async {
        final c = ReorgCalls();
        final clock = FakeExampleClock();
        await pumpReorg(t, c,
            clock: clock, patterns: _all, profile: kMg, commandsLeft: 0);
        await openHapticsTab(t, 'cues');
        await t.tap(_k('haptic-example-play:$s'));
        await t.pump();
        // First step is playing: exactly that row is highlighted, Stop shows.
        expect(clock.played, hasLength(1));
        expect(withKeyPrefix(t, 'haptic-slot-playing:').length, 1);
        expect(_k('haptic-slot-playing:${clock.played.first}'), findsOneWidget);
        expect(_k('haptic-example-stop:$s'), findsOneWidget);
        await clock.next(t); // step finished: a gap follows
        expect(clock.log.last, 'wait', reason: 'no gap between steps');
        await clock.next(t); // gap over: the next step
        if (clock.pending > 0 && clock.log.last.startsWith('play:')) {
          expect(_k('haptic-slot-playing:${clock.played.last}'),
              findsOneWidget);
          expect(withKeyPrefix(t, 'haptic-slot-playing:').length, 1);
        }
        await clock.drain(t);
        expect(clock.waits, isNotEmpty);
        expect(clock.waits.every((d) => d > Duration.zero), isTrue);
        // Done: no highlight, no Stop, the button is back.
        expect(withKeyPrefix(t, 'haptic-slot-playing:'), isEmpty);
        expect(_k('haptic-example-stop:$s'), findsNothing);
        expect(_k('haptic-example-play:$s'), findsOneWidget);
        // Examples are not limit-bound previews.
        expect(c.played, isEmpty);
        expect(c.buzzed, 0);
      });

      testWidgets('$s: Stop ends the example and nothing more plays',
          (t) async {
        final clock = FakeExampleClock();
        await pumpReorg(t, ReorgCalls(),
            clock: clock, patterns: _all, profile: kMg);
        await openHapticsTab(t, 'cues');
        await t.tap(_k('haptic-example-play:$s'));
        await t.pump();
        await clock.next(t);
        await t.tap(_k('haptic-example-stop:$s'));
        await t.pump();
        final before = clock.played.length;
        await clock.drain(t);
        expect(clock.played.length, before, reason: 'played after Stop');
        expect(withKeyPrefix(t, 'haptic-slot-playing:'), isEmpty);
        expect(_k('haptic-example-stop:$s'), findsNothing);
        expect(_k('haptic-example-play:$s'), findsOneWidget);
      });
    }
  });

  group('5. phone playback', () {
    testWidgets('Settings tab has the toggle and its remark; it reports the '
        'new value and reflects the stored one', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openSettingsTab(t);
      final tog = _k('haptics-phone-also');
      expect(tog, findsOneWidget);
      expect(find.text('Also play vibrations on the phone'), findsOneWidget);
      expect(find.textContaining('falls back to the phone'), findsOneWidget);
      expect(
          t.widget<Switch>(find.descendant(of: tog, matching: find.byType(Switch))).value,
          isFalse);
      await t.tap(tog);
      await t.pumpAndSettle();
      expect(c.phoneToggles, [true]);

      await pumpReorg(t, ReorgCalls(),
          patterns: _all, profile: kMg, phoneAlso: true);
      await openSettingsTab(t);
      expect(
          t.widget<Switch>(find.descendant(
                  of: _k('haptics-phone-also'), matching: find.byType(Switch)))
              .value,
          isTrue);
    });

    test('the toggle is a persisted pref, written through the view', () {
      final prefs = File('lib/state/prefs.dart').readAsStringSync();
      expect(prefs, contains("'haptics_play_on_phone'"));
      final src = File('lib/ui2/profile/haptics_settings.dart')
          .readAsStringSync();
      expect(src, anyOf(contains('haptics_play_on_phone'), contains('hapticsPlayOnPhone')));
    });

    testWidgets('band disconnected + toggle on: a slot preview goes to the '
        'phone seam, not the band', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c,
          patterns: _all, profile: kMg, bandConnected: false, phoneAlso: true);
      await openHapticsTab(t, 'alerts');
      await t.tap(_k('haptic-slot-preview:alert.water'));
      await t.pumpAndSettle();
      expect(c.phone, ['alert.water']);
      expect(c.played, isEmpty);
    });

    testWidgets('band connected + toggle on: both play', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg, phoneAlso: true);
      await openHapticsTab(t, 'alerts');
      await t.tap(_k('haptic-slot-preview:alert.water'));
      await t.pumpAndSettle();
      expect(c.phone, ['alert.water']);
      expect([for (final s in c.played) s.patternId], ['alert.water']);
    });

    testWidgets('toggle off: the phone never vibrates, even with the band '
        'disconnected', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c,
          patterns: _all, profile: kMg, bandConnected: false);
      await openHapticsTab(t, 'alerts');
      await t.tap(_k('haptic-slot-preview:alert.water'));
      await t.pumpAndSettle();
      expect(c.phone, isEmpty);
      expect(c.played, isEmpty);
    });
  });

  group('6. the Band tab is Settings', () {
    testWidgets('the last tab reads Settings; Safety and Test stay; '
        'Calibration is developer-only', (t) async {
      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      final tabs = t.widget<SubTabs>(find.byType(SubTabs));
      expect(tabs.items.last, 'Settings');
      expect(tabs.items, isNot(contains('Band')));
      expect(HapticsTab.values.last.label, 'Settings');
      await openSettingsTab(t);
      expect(sectionTitles(t), containsAll(['Safety', 'Test']));
      expect(sectionTitles(t), isNot(contains('Calibration')));
      expect(_k('haptics-device-lab'), findsNothing);
      await pumpReorg(t, ReorgCalls(),
          patterns: _all, profile: kMg, devMode: true);
      await openSettingsTab(t);
      expect(sectionTitles(t), contains('Calibration'));
      expect(_k('haptics-device-lab'), findsOneWidget);
    });

    testWidgets('the pinned New from taps / notes header is on every tab',
        (t) async {
      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      for (final tab in ['patterns', 'alerts', 'activity', 'cues']) {
        await openHapticsTab(t, tab);
        expect(_k('haptics-new-taps'), findsOneWidget, reason: tab);
        expect(_k('haptics-new-notes'), findsOneWidget, reason: tab);
      }
      await openSettingsTab(t);
      expect(_k('haptics-new-taps'), findsOneWidget);
      expect(_k('haptics-new-notes'), findsOneWidget);
    });
  });

  group('7. the vocabulary probe is always in Settings', () {
    for (final dev in [false, true]) {
      testWidgets('probe item present and opens the probe (devMode=$dev)',
          (t) async {
        final c = ReorgCalls();
        await pumpReorg(t, c,
            patterns: _all, profile: kMg, devMode: dev);
        await openSettingsTab(t);
        expect(_k('haptics-probe'), findsOneWidget);
        await t.tap(_k('haptics-probe'));
        await t.pumpAndSettle();
        expect(c.probeOpened, 1);
      });
    }

    testWidgets('connected band with no vocabulary yet: a prompt to run the '
        'probe; with a vocabulary: no prompt', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: null);
      await openSettingsTab(t);
      expect(_k('haptics-probe'), findsOneWidget);
      final prompt = _k('haptics-probe-prompt');
      expect(prompt, findsOneWidget);
      expect(find.descendant(of: prompt, matching: find.textContaining('probe')),
          findsWidgets);
      await t.tap(prompt);
      await t.pumpAndSettle();
      expect(c.probeOpened, 1);

      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      await openSettingsTab(t);
      expect(_k('haptics-probe'), findsOneWidget);
      expect(_k('haptics-probe-prompt'), findsNothing);
    });
  });
}

/// Split [played] into runs, each starting at [start].
List<List<String>> _runs(List<String> played, String start) {
  final out = <List<String>>[];
  for (final k in played) {
    if (k == start) out.add([]);
    if (out.isEmpty) out.add([]);
    out.last.add(k);
  }
  return out;
}
