// HAPTICS (8AD) — Settings > The band > Haptics.
//
// Four groups: Patterns (the named patterns every Buzz pattern picker offers),
// Safety (allow long sequences, and what the band's rolling command limit and
// queue are doing), Test (buzz the band) and, in developer mode only,
// Calibration (the Device lab).
//
// [HapticsSettings] owns the one pattern store, the alert rules and the relay
// channels: editing or deleting a stored pattern rewrites every snapshot of it
// in all three places (propagatePattern) and persists both. [HapticsSettingsView]
// is the same screen as a pure function of its inputs, which is what the tests
// pump.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../haptics/band_queue.dart' show BandCommandLedger;
import '../../haptics/haptic_profile.dart';
import '../../haptics/pattern_store.dart';
import '../../notify/buzz_sequence.dart';
import '../../notify/notification_prefs.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'buzz_pattern.dart';
import 'device_lab.dart' show DeviceLab;
import 'haptic_pattern_editor.dart';
import 'pattern_picker.dart' show patternDetail;
import 'profile.dart';

const String _riskCaption = 'May cause harm to your device. Use at your own risk.';

/// The route. Loads the store, the alert rules and the relay channels; hands
/// [HapticsSettingsView] plain values and the callbacks that change them.
class HapticsSettings extends StatefulWidget {
  const HapticsSettings({super.key});

  @override
  State<HapticsSettings> createState() => _HapticsSettingsState();
}

class _HapticsSettingsState extends State<HapticsSettings> {
  HapticPatternStore? _store;
  NotificationPrefs _prefs = const NotificationPrefs();
  bool _allowLong = Prefs.allowLongHaptics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await HapticPatternStore.load();
    final prefs = await NotificationPrefs.load();
    if (!mounted) return;
    setState(() {
      _store = store;
      _prefs = prefs;
    });
  }

  AppState get _app => context.read<AppState>();

  /// Saves the store, then rewrites every snapshot of [id] in the alert rules
  /// and the relay channels: with [replacement] they follow it; without one
  /// (the pattern was deleted) they keep their rhythm and lose the id.
  Future<void> _commit(
    HapticPatternStore store,
    String id, {
    BuzzSequence? replacement,
  }) async {
    final app = _app;
    final relay = app.notificationRelay;
    await store.save();
    // Read the rules fresh: another screen may have saved since this opened.
    final fresh = await NotificationPrefs.load();
    final before = relay.controller.channels;
    final out = propagatePattern(
      id,
      prefs: fresh,
      channels: before,
      replacement: replacement,
    );
    var next = fresh;
    if (patternUsageCount(id, prefs: fresh, channels: before) > 0) {
      await out.prefs.save();
      next = out.prefs;
      for (final e in out.channels.entries) {
        final old = before[e.key];
        if (old == null ||
            jsonEncode(old.toJson()) != jsonEncode(e.value.toJson())) {
          await relay.setChannel(e.key, e.value);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _store = store;
      _prefs = next;
    });
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
    final store = _store ?? await HapticPatternStore.load();
    store.add(name, s);
    await store.save();
    if (!mounted) return;
    setState(() => _store = store);
  }

  Future<void> _replace(String id, BuzzSequence s) async {
    final store = _store ?? await HapticPatternStore.load();
    store.replace(id, s);
    await _commit(store, id, replacement: store.byId(id)!.sequence);
  }

  Future<void> _rename(String id, String name) => _run(() async {
    final store = _store ?? await HapticPatternStore.load();
    store.rename(id, name);
    await _commit(store, id, replacement: store.byId(id)!.sequence);
  });

  Future<void> _delete(String id) => _run(() async {
    final store = _store ?? await HapticPatternStore.load();
    store.delete(id);
    await _commit(store, id);
  });

  @override
  Widget build(BuildContext c) {
    final store = _store;
    if (store == null) {
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
    final channels = app.notificationRelay.controller.channels;
    return HapticsSettingsView(
      patterns: store.list,
      usageOf: (id) =>
          patternUsageCount(id, prefs: _prefs, channels: channels),
      profile: HapticDeviceProfile.forGeneration(app.device.generation),
      allowLong: _allowLong,
      devMode: Prefs.getBool(Prefs.devMode, false),
      commandsLeft: app.haptics.commandsLeft,
      queued: app.haptics.pending,
      bandConnected: app.engine.isConnected,
      onPlay: app.previewBuzzSequence,
      // The device page's Tools row: one dispatcher delivery in the band queue.
      onBuzz: app.buzzBand,
      onAllowLong: (v) {
        Prefs.setBool(Prefs.hapticsAllowLong, v);
        setState(() => _allowLong = v);
      },
      onAdd: _add,
      onReplace: _replace,
      onRename: _rename,
      onDelete: _delete,
      onDeviceLab: () => goto(c, const DeviceLab()),
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
                  SettingsAccordion('Patterns', children: _patternRows(c, p)),
                  SettingsAccordion('Safety', children: _safetyRows(c, p)),
                  SettingsAccordion('Test', children: [
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
                    SettingsAccordion('Calibration', children: [
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

  List<Widget> _patternRows(BuildContext c, P p) => [
    if (patterns.isEmpty)
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
      for (final s in patterns) _patternRow(c, p, s),
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

  void _openSheet(BuildContext c, SavedHapticPattern s) {
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
                if (profile != null)
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
