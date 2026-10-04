// Shared helpers for the 8AI G4 (haptics screen, presets, editor, encoder) and
// G5 (gestures) red tests. Test-only; nothing here is production API.
//
// Everything new in lib/ is reached through strings, widget keys, `dynamic`
// calls or Function.apply with a plain-view fallback (the zone_alert_test.dart
// trick), so a missing name fails the one test that needs it, on what it
// asserts, and not the whole file at compile time.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';

import '../../phase8/support/sections.dart';

final HapticDeviceProfile kMg = HapticDeviceProfile.whoopMg;

/// The ten built-in presets the spec names, in the order it lists them. The
/// multiplication sign is U+00D7, as in "Hip hip hooray ×2".
const List<String> kPresetNames = [
  'One pulse',
  'Two pulses',
  'Three pulses',
  'Four pulses',
  'Five pulses',
  'One long pulse',
  'Two long pulses',
  'Three long pulses',
  'SOS',
  'Hip hip hooray ×2',
];

/// The alert rules that have no built-in pattern today (alarms and wake play
/// fixed plans in code; 'gesture' is not an alert slot since 8AI.3, its cues
/// are the gesture slots; 'breath' is not one since Oct 4, its cues are the
/// four breathing slots); every other rule in the registry is a slot with a
/// default pattern.
const Set<String> kRulesWithoutDefault = {
  'gesture',
  'breath',
  'alarm',
  'nativeAlarm',
  'wake',
  'alarmLatchFailed',
  'alarmNightCheck',
};

/// The slot key of every alert that plays a pattern, in registry order. The
/// key is the systemKey scheme 8AF.6 already uses (`alert.<ruleId>`).
List<String> alertSlotKeys() => [
      for (final id in NotificationPrefs.alertRuleOrder)
        if (!kRulesWithoutDefault.contains(id)) 'alert.$id',
    ];

/// The three gesture cue slots (8AF.6).
const List<String> kGestureSlotKeys = [
  'gesture.start',
  'gesture.followUp',
  'gesture.confirm',
];

/// The default pattern of a slot, through the existing seam.
BuiltInSpec? slotDefault(String slotKey) => builtInDefault(slotKey);

/// The spec of the preset called [name], found by name over every built-in the
/// registry lists (so no preset key is assumed), or null.
BuiltInSpec? presetByName(String name) {
  for (final k in builtInKeys()) {
    final s = builtInDefault(k);
    if (s != null && s.name == name) return s;
  }
  return null;
}

List<PatternEntry> notesOf(BuzzSequence s) =>
    PatternTranscript.parseCode(s.notes!).entries;

/// The lengths (sixteenths) of each pulse: a run of adjacent notes is one.
List<int> pulseLengths(List<PatternEntry> es) {
  final out = <int>[];
  var inNote = false;
  for (final e in es) {
    if (e.note) {
      if (inNote) {
        out[out.length - 1] += e.length;
      } else {
        out.add(e.length);
      }
      inNote = true;
    } else {
      inNote = false;
    }
  }
  return out;
}

/// The rests between pulses (sixteenths): adjacent rest entries add up, and
/// leading/trailing rests are not counted.
List<int> restsBetween(List<PatternEntry> es) => interiorRests(timeline(es));

/// The lengths of the rest runs strictly between the first and the last note
/// of a felt timeline (see `timeline` in haptic_compiler.dart).
List<int> interiorRests(List<PatternDynamic?> cells) {
  final first = cells.indexWhere((c) => c != null);
  final last = cells.lastIndexWhere((c) => c != null);
  if (first < 0) return const [];
  final out = <int>[];
  var run = 0;
  for (var i = first; i <= last; i++) {
    if (cells[i] == null) {
      run++;
    } else if (run > 0) {
      out.add(run);
      run = 0;
    }
  }
  return out;
}

/// A stable text for what a plan writes and how it is felt, to compare two
/// plans: the commands (effects, loop, write delay) and both felt renditions.
String planSignature(HapticPlan p) => [
      for (final s in p.steps)
        '${s.phrase.effects}x${s.phrase.loop}@${s.delayMs}',
      p.feltMin.join(' '),
      p.feltMax.join(' '),
    ].join(' | ');

/// Compile [code] for the MG the way the editor and delivery do: under the 10 s
/// cap, `*` notes without loudness weight unless [weight] says so.
HapticPlan? compileCode(
  String code, {
  int weight = 0,
  HapticPriority priority = HapticPriority.rhythm,
}) =>
    compile(
      PatternTranscript.parseCode(code).entries,
      kMg,
      dynamicWeight: weight,
      priority: priority,
      maxRuntimeMs: kMaxHapticRuntime.inMilliseconds,
    );

// ---------------------------------------------------------------------------
// The Haptics hub

class HubCalls {
  final added = <(String, BuzzSequence)>[];
  final replaced = <(String, BuzzSequence)>[];
  final renamed = <(String, String)>[];
  final deleted = <String>[];
  final played = <BuzzSequence>[];
  final assigned = <(String slotKey, String patternId)>[];
  final openedSections = <String>[];
  int buzzed = 0, lab = 0;

  /// Nothing about the store may change when a pattern is only assigned.
  bool get storeUntouched =>
      added.isEmpty && replaced.isEmpty && renamed.isEmpty && deleted.isEmpty;
}

BuzzSequence seqOf(String id, {String notes = 'N4mf R2 N4mf'}) => BuzzSequence(
      const [0, 625],
      durationsMs: const [500, 500],
      notes: notes,
      profileId: kMg.id,
      profileVersion: kMg.version,
      bakedSteps: [
        BakedStep(effects: const [47], loop: 1, delayMs: 0),
        BakedStep(effects: const [14], loop: 1, delayMs: 300),
      ],
      patternId: id,
    );

SavedHapticPattern userPattern(String id, String name) =>
    SavedHapticPattern(id: id, name: name, sequence: seqOf(id));

SavedHapticPattern presetPattern(String id, String name, String key) =>
    SavedHapticPattern(
      id: id,
      name: name,
      sequence: seqOf(id),
      systemKey: key,
    );

/// [HapticsSettingsView] with the 8AF.6 parameters filled in and the 8AI ones
/// passed by name through Function.apply. A build without them gets the plain
/// view, so the test fails on what it asserts.
Widget hubView(
  HubCalls c, {
  List<SavedHapticPattern> patterns = const [],
  HapticDeviceProfile? profile,
  bool devMode = false,
  Map<String, String> slotNames = const {},
}) {
  final named = <Symbol, dynamic>{
    #patterns: patterns,
    #usageOf: (String _) => 0,
    #profile: profile,
    #allowLong: false,
    #devMode: devMode,
    #commandsLeft: 30,
    #queued: 0,
    #bandConnected: true,
    #onPlay: (BuzzSequence s) async {
      c.played.add(s);
      return true;
    },
    #onBuzz: () => c.buzzed++,
    #onAllowLong: (bool _) {},
    #onAdd: (String n, BuzzSequence s) => c.added.add((n, s)),
    #onReplace: (String id, BuzzSequence s) => c.replaced.add((id, s)),
    #onRename: (String id, String n) => c.renamed.add((id, n)),
    #onDelete: c.deleted.add,
    #onDeviceLab: () => c.lab++,
    // 8AI (assumed): which pattern a slot plays now, by name.
    #slotPatternName: (String key) => slotNames[key] ?? 'Two pulses',
    // 8AI (assumed): a section's link to the screen where its slots are used.
    #onOpenSlotScreen: (String sectionId) => c.openedSections.add(sectionId),
    // 8AI (assumed): put a stored pattern on a slot.
    #onAssignToSlot: (String key, SavedHapticPattern p) =>
        c.assigned.add((key, p.id)),
  };
  try {
    return Function.apply(HapticsSettingsView.new, const [], named) as Widget;
  } on NoSuchMethodError {
    return HapticsSettingsView(
      patterns: patterns,
      usageOf: (_) => 0,
      profile: profile,
      allowLong: false,
      devMode: devMode,
      commandsLeft: 30,
      queued: 0,
      bandConnected: true,
      onPlay: (s) async {
        c.played.add(s);
        return true;
      },
      onBuzz: () => c.buzzed++,
      onAllowLong: (_) {},
      onAdd: (n, s) => c.added.add((n, s)),
      onReplace: (id, s) => c.replaced.add((id, s)),
      onRename: (id, n) => c.renamed.add((id, n)),
      onDelete: c.deleted.add,
      onDeviceLab: () => c.lab++,
    );
  }
}

Future<void> pumpHub(
  WidgetTester t,
  HubCalls c, {
  List<SavedHapticPattern> patterns = const [],
  HapticDeviceProfile? profile,
  bool devMode = false,
  Map<String, String> slotNames = const {},
}) =>
    pumpTall(
      t,
      hubView(
        c,
        patterns: patterns,
        profile: profile,
        devMode: devMode,
        slotNames: slotNames,
      ),
    );

/// Every widget whose key is a String key starting with [prefix], in the tree.
Iterable<Widget> withKeyPrefix(WidgetTester t, String prefix) =>
    t.allWidgets.where((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith(prefix);
    });

Finder byKeyText(String key) => find.byKey(ValueKey(key));
