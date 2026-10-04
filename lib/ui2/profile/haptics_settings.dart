// HAPTICS (8AD) — Settings > The band > Haptics.
//
// Groups, in order: Your patterns (the wearer's saved patterns), Presets (the
// built-in ones: the ten presets are read-only, the gesture cues can be
// customised and put back; none can be renamed or deleted), Where patterns are
// used (every alert and gesture cue that plays a pattern, by the NAME of the
// pattern, grouped by section with a link to the screen where it is set),
// Safety (allow long sequences, and what the band's rolling command limit and
// queue are doing), Test (buzz the band) and, in developer mode only,
// Calibration (the Device lab).
//
// [HapticsSettings] reads one settings snapshot (patterns, alert rules, relay
// channels): editing or deleting a stored pattern rewrites every snapshot of it
// in all three places (propagatePattern) in ONE settings update. [HapticsSettingsView]
// is the same screen as a pure function of its inputs, which is what the tests
// pump.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../haptics/band_queue.dart' show BandCommandLedger;
import '../../haptics/builtin_patterns.dart' show isPresetKey, kPresets;
import '../../haptics/haptic_profile.dart';
import '../../haptics/haptic_slots.dart';
import '../../haptics/pattern_store.dart';
import '../../notify/buzz_sequence.dart';
import '../../settings/settings_repository.dart';
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'buzz_pattern.dart';
import 'device_lab.dart' show DeviceLab;
import 'band_notifications.dart' show BandNotifications;
import 'gestures.dart' show BandGestures;
import 'haptic_pattern_editor.dart';
import 'pattern_picker.dart' show patternDetail, showPatternPicker;
import 'profile.dart';
import 'settings.dart' show NotificationSettings;

const String _riskCaption = 'May cause harm to your device. Use at your own risk.';

/// The route. Loads the store, the alert rules and the relay channels; hands
/// [HapticsSettingsView] plain values and the callbacks that change them.
class HapticsSettings extends StatefulWidget {
  const HapticsSettings({super.key});

  @override
  State<HapticsSettings> createState() => _HapticsSettingsState();
}

class _HapticsSettingsState extends State<HapticsSettings> {
  SettingsSnapshot? _snap;
  bool _allowLong = Prefs.allowLongHaptics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snap = await SettingsRepository.instance.read();
    if (!mounted) return;
    setState(() => _snap = snap);
  }

  /// One settings update: [edit] changes the store, then every snapshot of
  /// [id] in the alert rules and the relay channels follows it (with the
  /// pattern's sequence, or, when [deleted], keeping its rhythm and losing the
  /// id). The store, the rules and the channels are written together or not at
  /// all, and the relay hears the change on the repository's stream.
  Future<void> _commit(
    String id,
    void Function(HapticPatternStore store) edit, {
    bool deleted = false,
  }) async {
    final repo = SettingsRepository.instance;
    await repo.update((d) {
      edit(d.patterns);
      d.propagatePattern(
        id,
        replacement: deleted ? null : d.patterns.byId(id)!.sequence,
      );
    });
    // Read fresh: another screen may have saved since this opened.
    final fresh = await repo.read();
    if (!mounted) return;
    setState(() => _snap = fresh);
  }

  Future<void> _run(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save that change.')),
      );
    }
  }

  // Add and replace let a failure through: the screen that asked (the editor,
  // the name dialog) is still open and says so, so the take is not lost.
  Future<void> _add(String name, BuzzSequence s) async {
    final repo = SettingsRepository.instance;
    await repo.update(
      (d) => d.patterns.add(name, s),
      sections: {SettingsSection.patterns},
    );
    final fresh = await repo.read();
    if (!mounted) return;
    setState(() => _snap = fresh);
  }

  Future<void> _replace(String id, BuzzSequence s) =>
      _commit(id, (store) => store.replace(id, s));

  Future<void> _rename(String id, String name) =>
      _run(() => _commit(id, (store) => store.rename(id, name)));

  Future<void> _delete(String id) =>
      _run(() => _commit(id, (store) => store.delete(id), deleted: true));

  Future<void> _reset(String id) =>
      _run(() => _commit(id, (store) => store.resetToDefault(id)));

  /// Puts [p] on slot [key] (8AI): an alert's rule (or the relay's apps
  /// channel) holds a snapshot of it, a gesture cue holds its id. The store
  /// itself is not edited. [p] null puts the slot back on its default.
  Future<void> _assign(String key, SavedHapticPattern? p) async {
    final repo = SettingsRepository.instance;
    final seq = p?.sequence.copyWith(patternId: p.id);
    if (isGestureCueSlot(key)) {
      await repo.update((d) {
        final m = {
          ...decodeCueAssignments(Prefs.getString(Prefs.hapticsCueAssign, '')),
        };
        if (p == null) {
          m.remove(key);
        } else {
          m[key] = p.id;
        }
        d.setString(Prefs.hapticsCueAssign, encodeCueAssignments(m));
      }, sections: const {});
    } else if (key == kRelaySlotKey) {
      await repo.update((d) {
        final cfg = d.channels[kRelaySlotChannel];
        if (cfg == null) return;
        d.channels = {
          ...d.channels,
          kRelaySlotChannel: seq == null
              ? cfg.copyWith(clearBuzzSequence: true)
              : cfg.copyWith(buzzSequence: seq),
        };
      }, sections: {SettingsSection.channels});
    } else {
      final id = key.substring('alert.'.length);
      await repo.update((d) {
        final rule = {...d.alerts.alertRule(id).toJson()};
        if (seq == null) {
          rule.remove('buzzSequence');
        } else {
          rule['buzzSequence'] = seq.toJson();
        }
        d.alerts = d.alerts.withAlertRule(rule);
      }, sections: {SettingsSection.alerts});
    }
    await _load();
  }

  // The screen where a section's slots are set.
  void _openSlotScreen(BuildContext c, String sectionId) => goto(
        c,
        switch (sectionId) {
          'apps' => const BandNotifications(),
          'gestures' => const BandGestures(),
          _ => const NotificationSettings(),
        },
      );

  @override
  Widget build(BuildContext c) {
    final snap = _snap;
    if (snap == null) {
      return Scaffold(
        backgroundColor: P.of(c).bg,
        body: const SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: Align(
              alignment: Alignment.topCenter,
              child: NavBar('Haptics'),
            ),
          ),
        ),
      );
    }
    // Watched, so the ledger read-out and the queue follow AppState's updates
    // (the ledger and the queue are not notifiers themselves).
    final app = c.watch<AppState>();
    final caps = c.caps;
    return HapticsSettingsView(
      patterns: snap.patterns,
      usageOf: snap.patternUsage,
      profile: caps.hapticProfile,
      allowLong: _allowLong,
      devMode: caps.has(Feature.developerMode),
      commandsLeft: app.haptics.commandsLeft,
      queued: app.haptics.pending,
      bandConnected: caps.has(Feature.bandBuzz),
      onPlay: app.previewBuzzSequence,
      // The device page's Tools row: one dispatcher delivery in the band queue.
      onBuzz: app.buzzBand,
      onAllowLong: (v) {
        setState(() => _allowLong = v);
        // Through the repository, with the other settings writes.
        SettingsRepository.instance
            .update(
              (d) => d.setBool(Prefs.hapticsAllowLong, v),
              sections: const {},
            )
            .then<void>((_) {}, onError: (Object _) {});
      },
      onAdd: _add,
      onReplace: _replace,
      onRename: _rename,
      onDelete: _delete,
      onReset: _reset,
      onDeviceLab: () => goto(c, const DeviceLab()),
      slotPatternName: (key) => slotPatternLabel(
        key,
        patterns: snap.patterns,
        alerts: snap.alerts,
        channels: snap.channels,
        cueAssignments:
            decodeCueAssignments(Prefs.getString(Prefs.hapticsCueAssign, '')),
      ),
      onOpenSlotScreen: (id) => _openSlotScreen(c, id),
      onAssignToSlot: (key, p) => _assign(key, p),
      onResetSlot: (key) => _assign(key, null),
    );
  }
}

/// The screen, as a pure function of its inputs.
class HapticsSettingsView extends StatelessWidget {
  const HapticsSettingsView({
    super.key,
    required this.patterns,
    required this.usageOf,
    required this.profile,
    required this.allowLong,
    required this.devMode,
    required this.commandsLeft,
    required this.queued,
    required this.bandConnected,
    required this.onPlay,
    required this.onBuzz,
    required this.onAllowLong,
    required this.onAdd,
    required this.onReplace,
    required this.onRename,
    required this.onDelete,
    required this.onDeviceLab,
    this.onReset,
    this.slotPatternName,
    this.onOpenSlotScreen,
    this.onAssignToSlot,
    this.onResetSlot,
  });

  /// The stored patterns, in the order to show them.
  final List<SavedHapticPattern> patterns;

  /// How many alerts and channels hold a snapshot of the pattern with this id.
  final int Function(String id) usageOf;

  /// The connected band's haptic vocabulary (an MG); null on a 4.0, where the
  /// notes features are hidden and tap patterns still work.
  final HapticDeviceProfile? profile;
  final bool allowLong, devMode, bandConnected;

  /// Band commands left in the rolling window, and jobs waiting in the queue.
  final int commandsLeft, queued;

  final Future<bool> Function(BuzzSequence) onPlay;
  final VoidCallback onBuzz, onDeviceLab;
  final ValueChanged<bool> onAllowLong;
  /// Store a new pattern / replace one. They may complete later and throw: the
  /// screen that asked stays open until they succeed.
  final FutureOr<void> Function(String name, BuzzSequence s) onAdd;
  final FutureOr<void> Function(String id, BuzzSequence s) onReplace;
  final void Function(String id, String name) onRename;
  final ValueChanged<String> onDelete;

  /// Puts a built-in pattern back to its default.
  final ValueChanged<String>? onReset;

  /// What the slot with this key (see haptic_slots.dart) plays now, by NAME.
  /// Null: the rows say "Default".
  final String Function(String slotKey)? slotPatternName;

  /// Opens the screen where a section's slots are set; null hides the links.
  final void Function(String sectionId)? onOpenSlotScreen;

  /// Puts a stored pattern or preset on a slot without editing the store. May
  /// complete later and throw (the view says so). Null hides "Use on a slot"
  /// and makes the slot rows inert.
  final FutureOr<void> Function(String slotKey, SavedHapticPattern pattern)?
      onAssignToSlot;

  /// Puts a slot back on its default.
  final void Function(String slotKey)? onResetSlot;

  List<String> get _names => [for (final p in patterns) p.name];

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar('Haptics'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                children: [
                  SettingsAccordion('Your patterns',
                      id: 'haptics_your_patterns',
                      children: _yourRows(c, p)),
                  SettingsAccordion('Presets',
                      id: 'haptics_presets', children: _presetRows(c, p)),
                  SettingsAccordion('Where patterns are used',
                      id: 'haptics_where_used', children: _slotRows(c, p)),
                  SettingsAccordion('Safety',
                      id: 'haptics_safety', children: _safetyRows(c, p)),
                  SettingsAccordion('Test', id: 'haptics_test', children: [
                    SetRow(
                      LucideIcons.bellRing,
                      C.orange,
                      'Buzz the band',
                      key: const ValueKey('haptics-buzz'),
                      enabled: bandConnected,
                      sub: bandConnected
                          ? 'Vibrate the band to locate it'
                          : 'Connect to the band first',
                      chevron: false,
                      onTap: onBuzz,
                    ),
                  ]),
                  if (devMode)
                    SettingsAccordion('Calibration',
                        id: 'haptics_calibration',
                        children: [
                      SetRow(
                        LucideIcons.flaskConical,
                        C.purple,
                        'Device lab',
                        key: const ValueKey('haptics-device-lab'),
                        sub: 'Try gestures the band does not report on its own',
                        onTap: onDeviceLab,
                      ),
                    ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _yourRows(BuildContext c, P p) {
    final mine = [
      for (final s in patterns)
        if (!s.system) s,
    ];
    return [
      if (mine.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x3),
          child: Text(
            'No saved patterns yet. Record one from taps'
            '${profile != null ? ' or write one as notes' : ''}, '
            'then pick it for any alert.',
            style: F.over.copyWith(color: p.ink3),
          ),
        )
      else
        for (final s in mine) _patternRow(c, p, s),
      SetRow(
        LucideIcons.hand,
        C.blue,
        'New from taps',
        key: const ValueKey('haptics-new-taps'),
        sub: 'Tap out a rhythm',
        onTap: () => _newFromTaps(c),
      ),
      if (profile != null)
        SetRow(
          LucideIcons.music,
          C.blue,
          'New from notes',
          key: const ValueKey('haptics-new-notes'),
          sub: 'Notes and rests, with dynamics',
          onTap: () => _newFromNotes(c),
        ),
    ];
  }

  // The built-ins: the ten presets in their own order, then the rest (the
  // gesture cues, and a per-alert built-in the wearer had changed).
  List<Widget> _presetRows(BuildContext c, P p) {
    final order = [for (final k in kPresets) k.$1];
    int rank(SavedHapticPattern s) {
      final i = order.indexOf(s.systemKey ?? '');
      return i < 0 ? order.length : i;
    }

    final builtIn = [
      for (final s in patterns)
        if (s.system) s,
    ]..sort((a, b) => rank(a).compareTo(rank(b)));
    if (builtIn.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x3),
          child: Text('No presets to show.',
              style: F.over.copyWith(color: p.ink3)),
        ),
      ];
    }
    return [for (final s in builtIn) _patternRow(c, p, s)];
  }

  // Slots by section, each section under its header and a link to its screen.
  // No divider between two sections: the accordion already draws a hairline
  // above every row, header rows included, and a second one doubled the line.
  List<Widget> _slotRows(BuildContext c, P p) {
    final name = slotPatternName;
    return [
      for (var i = 0; i < kHapticSlotSections.length; i++) ...[
        Padding(
          key: ValueKey('haptic-slot-section:${kHapticSlotSections[i].id}'),
          padding: const EdgeInsets.symmetric(vertical: S.x2),
          child: Row(
            children: [
              Expanded(
                child: Text(kHapticSlotSections[i].title,
                    style: F.cap.copyWith(color: p.ink2)),
              ),
              if (onOpenSlotScreen != null)
                Pressable(
                  key: ValueKey(
                      'haptic-slot-section-link:${kHapticSlotSections[i].id}'),
                  onTap: () => onOpenSlotScreen!(kHapticSlotSections[i].id),
                  semanticLabel: 'Open ${kHapticSlotSections[i].title}',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Open',
                            style: F.cap.copyWith(
                                color: p.on(C.blue),
                                fontWeight: FontWeight.w700)),
                        Icon(LucideIcons.chevronRight,
                            size: 16, color: p.on(C.blue)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (final slot in kHapticSlotSections[i].slots)
          SetRow(
            LucideIcons.waves,
            C.purple,
            slot.label,
            key: ValueKey('haptic-slot:${slot.key}'),
            value: name == null ? 'Default' : name(slot.key),
            chevron: false,
            onTap: onAssignToSlot == null ? null : () => _pickForSlot(c, slot),
          ),
      ],
    ];
  }

  Widget _sectionHeader(P p, String label) => Padding(
    padding: const EdgeInsets.only(top: S.x2),
    child: Text(label, style: F.cap.copyWith(color: p.ink2)),
  );

  Widget _patternRow(BuildContext c, P p, SavedHapticPattern s) {
    final notes = s.sequence.notes;
    return Pressable(
      key: ValueKey('haptic-pattern:${s.id}'),
      onTap: () => _openSheet(c, s),
      semanticLabel: s.name,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.wash(C.purple),
                borderRadius: R.rSm,
              ),
              child: Icon(LucideIcons.waves, size: 16, color: p.on(C.purple)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name, style: F.body.copyWith(color: p.ink)),
                  if (notes != null)
                    Text(
                      notes,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: F.over.copyWith(color: p.ink3),
                    ),
                  Text(
                    patternDetail(s.sequence, profile: profile),
                    style: F.over.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: S.x2),
            if (s.system) ...[
              Icon(LucideIcons.lock, size: 14, color: p.ink3),
              const SizedBox(width: S.x2),
            ],
            Icon(LucideIcons.chevronRight, size: 17, color: p.ink3),
          ],
        ),
      ),
    );
  }

  List<Widget> _safetyRows(BuildContext c, P p) => [
    CheckboxListTile(
      key: const ValueKey('haptics-allow-long'),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.trailing,
      value: allowLong,
      title: Text(
        'Allow long sequences',
        style: F.body.copyWith(color: p.ink),
      ),
      subtitle: Text(
        '$_riskCaption The limit of 8 commands per pattern, the band queue '
        'and the 30 commands per 2 minutes still apply.',
        style: F.over.copyWith(color: p.ink3),
      ),
      onChanged: (v) {
        if (v == true) {
          _confirmAllow(c);
        } else {
          onAllowLong(false);
        }
      },
    ),
    Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$commandsLeft of ${BandCommandLedger.maxCommands} band commands '
            'left in the last 2 minutes',
            style: F.cap.copyWith(color: p.ink2),
          ),
          Text(
            queued > 0 ? 'Queue: $queued waiting' : 'Queue: empty',
            style: F.cap.copyWith(color: p.ink2),
          ),
        ],
      ),
    ),
  ];

  Future<void> _confirmAllow(BuildContext c) async {
    final ok = await showDialog<bool>(
      context: c,
      builder: (d) => AlertDialog(
        title: const Text('Allow long sequences?'),
        content: const Text(_riskCaption),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (ok == true) onAllowLong(true);
  }

  Future<bool> _play(BuildContext c, BuzzSequence s) async {
    try {
      return await onPlay(s);
    } catch (_) {
      return false;
    }
  }

  // The picker for one slot: any stored pattern or preset goes onto it, or its
  // default comes back. Making a new pattern is done under Your patterns.
  void _pickForSlot(BuildContext c, HapticSlot slot) {
    showPatternPicker(
      c,
      patterns: patterns,
      profile: profile,
      bandConnected: bandConnected,
      allowLong: allowLong,
      onPlay: onPlay,
      onDefault: () => onResetSlot?.call(slot.key),
      onChoose: (seq) {
        SavedHapticPattern? chosen;
        for (final s in patterns) {
          if (s.id == seq.patternId) chosen = s;
        }
        if (chosen != null) _assign(c, slot.key, chosen);
      },
    );
  }

  Future<void> _assign(
      BuildContext c, String slotKey, SavedHapticPattern s) async {
    try {
      await onAssignToSlot!(slotKey, s);
    } catch (_) {
      if (c.mounted) _saveFailed(c);
    }
  }

  // Every slot, grouped by section, for putting [s] on one.
  void _assignSheet(BuildContext c, SavedHapticPattern s) {
    final p = P.of(c);
    final name = slotPatternName;
    showModalBottomSheet<void>(
      context: c,
      backgroundColor: p.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            key: const ValueKey('haptic-assign-sheet'),
            padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: S.x2),
                  child: Text('Use "${s.name}" on',
                      style: F.head.copyWith(color: p.ink)),
                ),
                for (final section in kHapticSlotSections) ...[
                  _sectionHeader(p, section.title),
                  for (final slot in section.slots)
                    SetRow(
                      LucideIcons.waves,
                      C.purple,
                      slot.label,
                      key: ValueKey('haptic-assign-slot:${slot.key}'),
                      value: name == null ? '' : name(slot.key),
                      chevron: false,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _assign(c, slot.key, s);
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSheet(BuildContext c, SavedHapticPattern s) {
    // A preset is read-only: it can be played and put on a slot, nothing more.
    final preset = isPresetKey(s.systemKey ?? '');
    final p = P.of(c);
    showModalBottomSheet<void>(
      context: c,
      backgroundColor: p.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            key: const ValueKey('haptic-pattern-sheet'),
            padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: S.x2),
                  child: Text(s.name, style: F.head.copyWith(color: p.ink)),
                ),
                SetRow(
                  LucideIcons.play,
                  C.blue,
                  'Preview',
                  key: const ValueKey('haptic-action-preview'),
                  enabled: bandConnected,
                  sub: bandConnected ? '' : 'Connect to the band first',
                  chevron: false,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _preview(c, s.sequence);
                  },
                ),
                if (onAssignToSlot != null)
                  SetRow(
                    LucideIcons.waves,
                    C.blue,
                    'Use on a slot',
                    key: const ValueKey('haptic-action-assign'),
                    sub: 'An alert or a gesture cue',
                    chevron: false,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      _assignSheet(c, s);
                    },
                  ),
                if (profile != null && !preset)
                  SetRow(
                    LucideIcons.music,
                    C.blue,
                    'Edit notes',
                    key: const ValueKey('haptic-action-edit'),
                    chevron: false,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      _edit(c, s);
                    },
                  ),
                if (!preset)
                  SetRow(
                    LucideIcons.hand,
                    C.blue,
                    'Re-record',
                    key: const ValueKey('haptic-action-rerecord'),
                    chevron: false,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      _rerecord(c, s);
                    },
                  ),
                if (!preset)
                  if (s.system)
                  SetRow(
                    LucideIcons.rotateCcw,
                    C.blue,
                    'Reset to default',
                    key: const ValueKey('haptic-action-reset'),
                    chevron: false,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      onReset?.call(s.id);
                    },
                  )
                else ...[
                  SetRow(
                    LucideIcons.pencil,
                    C.blue,
                    'Rename',
                    key: const ValueKey('haptic-action-rename'),
                    chevron: false,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      _rename(c, s);
                    },
                  ),
                  SetRow(
                    LucideIcons.trash2,
                    C.red,
                    'Delete',
                    key: const ValueKey('haptic-action-delete'),
                    danger: true,
                    chevron: false,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      _confirmDelete(c, s);
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _preview(BuildContext c, BuzzSequence s) async {
    final ok = await _play(c, s);
    if (ok || !c.mounted) return;
    ScaffoldMessenger.of(c).showSnackBar(
      const SnackBar(content: Text('The phone could not send it to the band.')),
    );
  }

  void _edit(BuildContext c, SavedHapticPattern s) {
    final prof = profile;
    if (prof == null || !c.mounted) return;
    final nav = Navigator.of(c);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => HapticPatternEditorPage(
          initial: s.sequence,
          name: s.name,
          profile: prof,
          onPlay: onPlay,
          allowLong: allowLong,
          existingNames: _names,
          onSave: (name, seq) async {
            await onReplace(s.id, seq);
            if (nav.mounted) nav.pop();
          },
        ),
      ),
    );
  }

  void _rerecord(BuildContext c, SavedHapticPattern s) {
    if (!c.mounted) return;
    showBuzzPatternSheet(
      c,
      initial: s.sequence,
      bandConnected: bandConnected,
      onPlay: onPlay,
      profile: profile,
      allowLong: allowLong,
      // Edit as notes: saved in the editor, which does not ask a name.
      notesName: s.name,
      notesNames: _names,
      onSaveAsNotes: (_, seq) => onReplace(s.id, seq),
      onSave: (seq) async {
        try {
          await onReplace(s.id, seq);
        } catch (_) {
          if (c.mounted) _saveFailed(c);
        }
      },
    );
  }

  void _saveFailed(BuildContext c) => ScaffoldMessenger.of(c).showSnackBar(
    const SnackBar(content: Text('Could not save that change.')),
  );

  Future<void> _rename(BuildContext c, SavedHapticPattern s) async {
    if (!c.mounted) return;
    final name = await showDialog<String>(
      context: c,
      builder: (_) => PatternNameDialog(
        initial: s.name,
        taken: [
          for (final n in _names)
            if (n != s.name) n,
        ],
      ),
    );
    if (name != null) onRename(s.id, name);
  }

  Future<void> _confirmDelete(BuildContext c, SavedHapticPattern s) async {
    if (!c.mounted) return;
    final used = usageOf(s.id);
    final ok = await showDialog<bool>(
      context: c,
      builder: (d) => AlertDialog(
        title: Text('Delete "${s.name}"?'),
        content: used == 0
            ? null
            : Text(
                'Used by $used ${used == 1 ? 'alert' : 'alerts'}. '
                '${used == 1 ? 'It keeps' : 'They keep'} the rhythm but '
                '${used == 1 ? 'stops' : 'stop'} following this pattern.',
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) onDelete(s.id);
  }

  void _newFromTaps(BuildContext c) {
    showBuzzPatternSheet(
      c,
      bandConnected: bandConnected,
      onPlay: onPlay,
      profile: profile,
      allowLong: allowLong,
      // Edit as notes: the editor asks the name and stores the pattern.
      notesNames: _names,
      onSaveAsNotes: (name, seq) => onAdd(name, seq),
      // The sheet is closed by now; the take lives on in the name dialog,
      // which asks again (with what was typed and why) until the pattern is
      // stored or the wearer cancels.
      onSave: (seq) async {
        String? name;
        String? message;
        while (true) {
          if (!c.mounted) return;
          name = await showDialog<String>(
            context: c,
            builder: (_) => PatternNameDialog(
              taken: _names,
              initial: name,
              message: message,
            ),
          );
          if (name == null) return;
          try {
            await onAdd(name, seq);
            return;
          } catch (_) {
            message = 'Could not save that pattern. Try again.';
          }
        }
      },
    );
  }

  void _newFromNotes(BuildContext c) {
    final prof = profile;
    if (prof == null) return;
    final nav = Navigator.of(c);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => HapticPatternEditorPage(
          profile: prof,
          onPlay: onPlay,
          allowLong: allowLong,
          existingNames: _names,
          onSave: (name, seq) async {
            await onAdd(name, seq);
            if (nav.mounted) nav.pop();
          },
        ),
      ),
    );
  }
}
