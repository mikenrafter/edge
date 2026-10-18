// The Haptics screen says so on a slot whose pattern feels like another's in
// its confusable set. It only says so: assigning still works.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/pattern_similarity.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/haptics_screen_support.dart';
import '../../support/settings_sections.dart';

// [n] presses of 100 ms, 300 ms apart.
BuzzSequence _beats(int n) => BuzzSequence(
      [for (var i = 0; i < n; i++) i * 300],
      durationsMs: [for (var i = 0; i < n; i++) 100],
    );

Finder _line(String slotKey) =>
    find.byKey(ValueKey('haptic-slot-warning:$slotKey'));

String _text(WidgetTester t, String slotKey) {
  final texts = t.widgetList<Text>(
    find.descendant(of: _line(slotKey), matching: find.byType(Text)),
  );
  final own = t.widgetList<Widget>(_line(slotKey)).whereType<Text>();
  return [
    for (final x in [...texts, ...own]) x.data ?? x.textSpan?.toPlainText() ?? '',
  ].join('\n');
}

Future<void> _pump(
  WidgetTester t,
  Map<String, BuzzSequence> playing, {
  HubCalls? calls,
  bool wired = true,
}) async {
  final c = calls ?? HubCalls();
  await pumpTall(
    t,
    HapticsSettingsView(
      initialTab: HapticsTab.cues,
      patterns: [userPattern('a', 'Morning nudge'), userPattern('b', 'Evening')],
      usageOf: (_) => 0,
      profile: kMg,
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
      slotPatternName: (_) => 'Two pulses',
      slotSequence: wired ? (key) => playing[key] : null,
      onAssignToSlot: (k, p) => c.assigned.add((k, p.id)),
    ),
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  testWidgets('two breathing cues with the same beats each say so', (t) async {
    await _pump(t, {
      'breath.inhale': _beats(2),
      'breath.exhale': _beats(2),
      'breath.hold': _beats(5),
      'breath.done': _beats(7),
    });
    expect(_line('breath.inhale'), findsOneWidget);
    expect(_line('breath.exhale'), findsOneWidget);
    expect(_text(t, 'breath.inhale'), 'Feels like Exhale (same 2 beats)');
    expect(_text(t, 'breath.exhale'), 'Feels like Inhale (same 2 beats)');
  });

  testWidgets('a slot with nothing like it shows no line', (t) async {
    await _pump(t, {
      'breath.inhale': _beats(2),
      'breath.exhale': _beats(2),
      'breath.hold': _beats(5),
      'breath.done': _beats(7),
    });
    expect(_line('breath.hold'), findsNothing);
    expect(_line('breath.done'), findsNothing);
    expect(_line('gesture.start'), findsNothing);
  });

  testWidgets('lengths within 0.5 s say so, by length', (t) async {
    await _pump(t, {
      'breath.inhale': BuzzSequence(const [0], durationsMs: const [1000]),
      'breath.exhale':
          BuzzSequence(const [0, 1200], durationsMs: const [100, 300]),
    });
    expect(_text(t, 'breath.inhale'), 'Feels like Exhale (within 0.5 s)');
    expect(_text(t, 'breath.exhale'), 'Feels like Inhale (within 0.5 s)');
  });

  testWidgets('a slot like two others lists both', (t) async {
    await _pump(t, {
      'breath.inhale': _beats(2),
      'breath.exhale': _beats(2),
      'breath.hold': _beats(2),
    });
    final text = _text(t, 'breath.inhale');
    expect(text, contains('Feels like Exhale (same 2 beats)'));
    expect(text, contains('Feels like Hold (same 2 beats)'));
  });

  testWidgets('the gesture start does not warn against a breathing cue',
      (t) async {
    await _pump(t, {
      'gesture.start': _beats(2),
      'breath.inhale': _beats(2),
    });
    expect(_line('gesture.start'), findsNothing);
    expect(_line('breath.inhale'), findsNothing);
  });

  testWidgets('with no sequences given, the screen shows no warning', (t) async {
    await _pump(t, {
      'breath.inhale': _beats(2),
      'breath.exhale': _beats(2),
    }, wired: false);
    expect(_line('breath.inhale'), findsNothing);
    expect(_line('breath.exhale'), findsNothing);
  });

  testWidgets('a warned slot can still be assigned a pattern', (t) async {
    final c = HubCalls();
    await _pump(t, {
      'breath.inhale': _beats(2),
      'breath.exhale': _beats(2),
    }, calls: c);
    expect(_line('breath.exhale'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('haptic-slot:breath.exhale')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pattern-picker-row:b')));
    await t.pumpAndSettle();
    expect(c.assigned, [('breath.exhale', 'b')]);
    expect(t.takeException(), isNull);
  });

  test('the live screen passes the slots\' sequences to the view', () {
    final src = File('lib/ui2/profile/haptics_settings.dart').readAsStringSync();
    expect(src, contains('slotSequence:'),
        reason: 'HapticsSettings (the route) must hand HapticsSettingsView '
            'what each slot plays: cues from resolveCuePatterns, alerts from '
            'their rule or the relay channel');
    expect(src, contains('similarityWarnings('));
  });

  test('the warning text comes from similarityLine', () {
    expect(
      similarityLine(
        const SimilarityWarning(
          slotA: 'breath.inhale',
          slotB: 'breath.exhale',
          reason: SimilarityReason.sameBeats,
          beats: 2,
        ),
        other: 'Exhale',
      ),
      'Feels like Exhale (same 2 beats)',
    );
  });
}
