// Default rhythms are previewable.
//
// In the pattern picker the "Default" row (the rule's built-in pattern) shows
// its notes code and a plan summary, and has a Play button (key
// `pattern-picker-default-play`) that plays it through the normal preview path
// (the `onPlay` the picker is given, i.e. AppState.previewBuzzSequence: queue,
// lab hold, start signals) WITHOUT choosing it. Tapping the row itself still
// selects (onDefault). Built-in rows in the hub get the same Preview as every
// pattern.
//
// CONTRACT these tests pin that the spec leaves open:
//  - showPatternPicker takes `BuzzSequence? defaultSequence`: the rhythm the
//    "Default" row stands for (the rule's system pattern; on a band with no
//    profile it may be a taps-only sequence).
//  - the play button sits inside the `pattern-picker-default` row.
//  - the hub's built-in rows are the same `haptic-pattern:<id>` rows with the
//    same `haptic-action-preview` in their sheet. The system flag is written
//    through the pattern's JSON ('system', 'systemKey') so this file does not
//    depend on the Dart constructor shape that builtin_patterns_test pins.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/pattern_picker.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/settings_sections.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

const _notes = 'N4* R1 N4*';

final BuzzSequence _taps = BuzzSequence(const [0, 625],
    durationsMs: const [500, 500]);

/// The plan the default's summary comes from (planForTaps, not compile, so
/// this file does not depend on compile's `extended` parameter).
HapticPlan get _plan => planForTaps(_taps, _mg)!;

/// A stored MG rhythm of [notes] with a compiled plan, as the editor saves.
BuzzSequence _mgSeq(String notes, {String? patternId}) {
  final plan = _plan;
  return BuzzSequence(
    const [0, 625],
    durationsMs: const [500, 500],
    notes: notes,
    profileId: _mg.id,
    profileVersion: _mg.version,
    bakedSteps: [
      for (final s in plan.steps)
        BakedStep(
          effects: s.phrase.effects,
          loop: s.phrase.loop,
          delayMs: s.delayMs,
        ),
    ],
    bakedRuntimeMs: plan.runtimeMs,
    patternId: patternId,
  );
}

class _Picker {
  final played = <BuzzSequence>[];
  final chosen = <BuzzSequence>[];
  int defaults = 0;
}

Future<_Picker> _openPicker(
  WidgetTester t, {
  BuzzSequence? defaultSequence,
  HapticDeviceProfile? profile,
  bool bandConnected = true,
}) async {
  final r = _Picker();
  t.view.physicalSize = const Size(1170, 3000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Builder(
      builder: (c) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showPatternPicker(
              c,
              patterns: const [],
              profile: profile,
              bandConnected: bandConnected,
              defaultSequence: defaultSequence,
              onPlay: (s) async {
                r.played.add(s);
                return true;
              },
              onDefault: () => r.defaults++,
              onChoose: r.chosen.add,
              onSaveNew: (name, s) async => SavedHapticPattern(
                id: 'n1',
                name: name,
                sequence: s.copyWith(patternId: 'n1'),
              ),
            ),
            child: const Text('open picker'),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open picker'));
  await t.pumpAndSettle();
  return r;
}

const _defaultRow = ValueKey('pattern-picker-default');
const _defaultPlay = ValueKey('pattern-picker-default-play');

// The hub, as in haptics_settings_test.dart.
class _Hub {
  final played = <BuzzSequence>[];
}

Widget _hub(_Hub h, List<SavedHapticPattern> patterns,
        {HapticDeviceProfile? profile}) =>
    HapticsSettingsView(
      patterns: patterns,
      usageOf: (_) => 0,
      profile: profile,
      allowLong: false,
      devMode: false,
      commandsLeft: 30,
      queued: 0,
      bandConnected: true,
      onPlay: (s) async {
        h.played.add(s);
        return true;
      },
      onBuzz: () {},
      onAllowLong: (_) {},
      onAdd: (n, s) {},
      onReplace: (id, s) {},
      onRename: (id, n) {},
      onDelete: (_) {},
      onDeviceLab: () {},
    );

SavedHapticPattern _builtIn(String id, String key, BuzzSequence s) =>
    SavedHapticPattern.fromJson({
      'id': id,
      'name': 'Built in $key',
      'sequence': (s.copyWith(patternId: id)).toJson(),
      'system': true,
      'systemKey': key,
    });

void main() {
  group('the picker\'s Default row is previewable', () {
    testWidgets('it shows the notes of the default rhythm', (t) async {
      await _openPicker(t, defaultSequence: _mgSeq(_notes), profile: _mg);
      expect(
        find.descendant(of: find.byKey(_defaultRow), matching: find.textContaining(_notes)),
        findsOneWidget,
      );
    });

    testWidgets('it shows the plan summary of the default rhythm', (t) async {
      final def = _mgSeq(_notes);
      await _openPicker(t, defaultSequence: def, profile: _mg);
      final summary = _plan.summary;
      final detail = patternDetail(def, profile: _mg);
      Finder inRow(String s) => find.descendant(
          of: find.byKey(_defaultRow), matching: find.textContaining(s));
      expect(
        inRow(summary).evaluate().isNotEmpty ||
            inRow(detail).evaluate().isNotEmpty,
        isTrue,
        reason: 'expected "$summary" or "$detail" in the Default row',
      );
    });

    testWidgets('it has a Play button', (t) async {
      await _openPicker(t, defaultSequence: _mgSeq(_notes), profile: _mg);
      expect(find.byKey(_defaultPlay), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(_defaultRow), matching: find.byKey(_defaultPlay)),
        findsOneWidget,
        reason: 'the button belongs to the Default row',
      );
    });

    testWidgets('Play previews the default through onPlay and selects '
        'nothing', (t) async {
      final def = _mgSeq(_notes);
      final r = await _openPicker(t, defaultSequence: def, profile: _mg);
      await t.tap(find.byKey(_defaultPlay));
      await t.pumpAndSettle();
      expect(r.played, hasLength(1));
      expect(r.played.single.notes, _notes);
      expect(r.played.single.bakedSteps!.map((s) => s.effects),
          def.bakedSteps!.map((s) => s.effects));
      expect(r.defaults, 0, reason: 'previewing is not choosing');
      expect(r.chosen, isEmpty);
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget,
          reason: 'the picker stays open to compare');
    });

    testWidgets('choosing the Default row still selects it, and plays '
        'nothing', (t) async {
      final r =
          await _openPicker(t, defaultSequence: _mgSeq(_notes), profile: _mg);
      await t.tap(find.byKey(_defaultRow));
      await t.pumpAndSettle();
      expect(r.defaults, 1);
      expect(r.played, isEmpty);
    });

    testWidgets('on a band with no profile the default taps are previewable '
        'too', (t) async {
      final taps = BuzzSequence([0, 400, 800]);
      final r = await _openPicker(t, defaultSequence: taps);
      expect(find.byKey(_defaultPlay), findsOneWidget);
      await t.tap(find.byKey(_defaultPlay));
      await t.pumpAndSettle();
      expect(r.played.single.offsetsMs, [0, 400, 800]);
      expect(r.defaults, 0);
    });
  });

  group('built-in rows in the hub are previewable', () {
    final start = _mgSeq('N2mf R2 N2mf');

    testWidgets('a built-in row opens a sheet with Preview, which plays it',
        (t) async {
      final h = _Hub();
      await pumpTall(
          t, _hub(h, [_builtIn('sys-start', 'gesture.start', start)], profile: _mg));
      await t.tap(find.byKey(const ValueKey('haptic-pattern:sys-start')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('haptic-action-preview')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('haptic-action-preview')));
      await t.pumpAndSettle();
      expect(h.played, hasLength(1));
      expect(h.played.single.notes, 'N2mf R2 N2mf');
    });

    testWidgets('the same on a band with no profile (taps)', (t) async {
      final h = _Hub();
      final taps = BuzzSequence([0, 300]);
      await pumpTall(
          t, _hub(h, [_builtIn('sys-water', 'alert.water', taps)]));
      await t.tap(find.byKey(const ValueKey('haptic-pattern:sys-water')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('haptic-action-preview')));
      await t.pumpAndSettle();
      expect(h.played.single.offsetsMs, [0, 300]);
    });
  });
}
