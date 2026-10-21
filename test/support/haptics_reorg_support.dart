// Harness for the haptics page reorganisation tests (haptics_reorg_test.dart).
//
// Every API that does not exist yet is reached by NAME through Function.apply
// (the haptics_screen_support.dart trick): a build without it falls back to
// the plain view, so a test fails on what it asserts, not at compile time.
//
// New named parameters of HapticsSettingsView these tests assume (green adds
// them; names are the contract):
//   phoneAlso            bool                         the "also on the phone" toggle
//   onPhoneAlso          ValueChanged<bool>           the wearer flipped it
//   phoneVibrate         Future<void> Function(BuzzSequence)
//                                                     the phone-vibration seam
//   examplePlayer        Future<bool> Function(BuzzSequence)
//                                                     plays one example step,
//                                                     ignoring the buzz limit
//   sequenceWait         Future<void> Function(Duration)
//                                                     the gap clock between steps
//   onOpenProbe          VoidCallback                 opens the vocabulary probe
//
// New widget keys: haptic-slot-staff:<slot>, haptic-slot-preview:<slot>,
// haptic-preset:<patternId>, haptic-preset-confirm(+ -ok),
// haptic-example-play:<section>, haptic-example-stop:<section>,
// haptic-example-note:<section>, haptic-slot-playing:<slot>,
// haptics-phone-also, haptics-probe, haptics-probe-prompt.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show SubTabs;

import 'haptics_screen_support.dart';
import 'settings_sections.dart';

/// Everything the new seams were called with.
class ReorgCalls extends HubCalls {
  final phone = <String?>[]; // patternId of each phone vibration
  final phoneToggles = <bool>[];
  int probeOpened = 0;
}

/// A fake example player and gap clock: nothing finishes until the test says
/// so, so there is no real time and every step can be observed.
class FakeExampleClock {
  /// 'play:<slot>' and 'wait' in the order they were requested.
  final log = <String>[];
  final waits = <Duration>[];
  final _pending = <Completer<void>>[];

  List<String> get played => [
        for (final e in log)
          if (e.startsWith('play:')) e.substring(5),
      ];

  int get pending => _pending.length;

  Future<bool> play(BuzzSequence s) async {
    log.add('play:${s.patternId}');
    final c = Completer<void>();
    _pending.add(c);
    await c.future;
    return true;
  }

  Future<void> wait(Duration d) async {
    log.add('wait');
    waits.add(d);
    final c = Completer<void>();
    _pending.add(c);
    await c.future;
  }

  /// Finish the oldest pending step and let the view react.
  Future<void> next(WidgetTester t) async {
    if (_pending.isEmpty) return;
    _pending.removeAt(0).complete();
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
  }

  Future<void> drain(WidgetTester t, {int max = 200}) async {
    var n = 0;
    while (_pending.isNotEmpty && n++ < max) {
      await next(t);
    }
  }
}

/// A sequence whose patternId is the slot key, so a played sequence names its
/// slot.
BuzzSequence slotSeq(String slotKey) => seqOf(slotKey);

Widget reorgView(
  ReorgCalls c, {
  FakeExampleClock? clock,
  List<SavedHapticPattern> patterns = const [],
  HapticDeviceProfile? profile,
  bool devMode = false,
  bool bandConnected = true,
  bool phoneAlso = false,
  int commandsLeft = 30,
  HapticsTab? initialTab,
}) {
  final named = <Symbol, dynamic>{
    #patterns: patterns,
    #usageOf: (String _) => 0,
    #profile: profile,
    #allowLong: false,
    #devMode: devMode,
    #commandsLeft: commandsLeft,
    #queued: 0,
    #bandConnected: bandConnected,
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
    #slotPatternName: (String key) => 'Two pulses',
    #slotSequence: (String key) => slotSeq(key),
    #onOpenSlotScreen: (String id) => c.openedSections.add(id),
    #onAssignToSlot: (String key, SavedHapticPattern p) =>
        c.assigned.add((key, p.id)),
    #initialTab: initialTab,
    // The new seams.
    #phoneAlso: phoneAlso,
    #onPhoneAlso: (bool v) => c.phoneToggles.add(v),
    #phoneVibrate: (BuzzSequence s) async {
      c.phone.add(s.patternId);
    },
    #onOpenProbe: () => c.probeOpened++,
    if (clock != null) #examplePlayer: clock.play,
    if (clock != null) #sequenceWait: clock.wait,
  };
  try {
    return Function.apply(HapticsSettingsView.new, const [], named) as Widget;
  } on NoSuchMethodError {
    // The plain view: the new names are not there yet.
    return hubView(c,
        patterns: patterns, profile: profile, devMode: devMode);
  }
}

Future<void> pumpReorg(
  WidgetTester t,
  ReorgCalls c, {
  FakeExampleClock? clock,
  List<SavedHapticPattern> patterns = const [],
  HapticDeviceProfile? profile,
  bool devMode = false,
  bool bandConnected = true,
  bool phoneAlso = false,
  int commandsLeft = 30,
  HapticsTab? initialTab,
}) =>
    pumpTall(
      t,
      reorgView(c,
          clock: clock,
          patterns: patterns,
          profile: profile,
          devMode: devMode,
          bandConnected: bandConnected,
          phoneAlso: phoneAlso,
          commandsLeft: commandsLeft,
          initialTab: initialTab),
    );

/// Select the LAST tab (Settings, formerly Band) by its own key, whatever id it
/// ends up with.
Future<void> openSettingsTab(WidgetTester t) async {
  Finder lastTab() {
    final k = t.widget<SubTabs>(find.byType(SubTabs)).itemKeys!.last;
    return find.byKey(k!);
  }

  for (var i = 0; i < 6 && lastTab().evaluate().isEmpty; i++) {
    await t.drag(find.byType(SubTabs), const Offset(-200, 0));
    await t.pumpAndSettle();
  }
  await Scrollable.ensureVisible(t.element(lastTab()), alignment: .5);
  await t.pumpAndSettle();
  await t.tap(lastTab());
  await t.pumpAndSettle();
}

List<String> slotKeysOf(String sectionId) => [
      for (final s in kHapticSlotSections)
        if (s.id == sectionId) for (final k in s.slots) k.key,
    ];
