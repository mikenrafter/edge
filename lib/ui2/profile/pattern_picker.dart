// PATTERN PICKER (8AD) — the sheet the Buzz pattern rows in Notifications and
// Band notifications open before the tap sheet.
//
// Default clears the rule to the registry default; a stored pattern is chosen as
// a SNAPSHOT of it, carrying its patternId; "Record new" is today's tap sheet,
// which here (and only here) can also save the take to the store; "Write
// notes" opens the advanced editor and is for a band with a haptic profile (an
// MG) only. The picker does not touch the store itself: the caller hands it the
// patterns and an [onSaveNew] that stores one and returns it, so the choice can
// carry its id.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../haptics/haptic_profile.dart';
import '../../haptics/pattern_store.dart';
import '../../notify/buzz_sequence.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'buzz_pattern.dart';
import 'haptic_pattern_editor.dart';

/// Stores a new pattern and returns it (with its id). Throws ArgumentError for
/// a bad or taken name.
Future<SavedHapticPattern> saveNewPattern(String name, BuzzSequence s) async {
  final store = await HapticPatternStore.load();
  final p = store.add(name, s);
  await store.save();
  return p;
}

/// What a stored pattern reads as: "N commands · ~X s" for notes, "Taps"
/// without them.
String patternDetail(BuzzSequence s) {
  if (s.notes == null) return 'Taps';
  final secs = (s.playTime.inMilliseconds / 1000).toStringAsFixed(1);
  final steps = s.bakedSteps?.length;
  return steps == null
      ? '~$secs s'
      : '$steps ${steps == 1 ? 'command' : 'commands'} · ~$secs s';
}

/// Opens the picker. [c] must stay mounted for the follow-up sheet or page.
Future<void> showPatternPicker(
  BuildContext c, {
  required List<SavedHapticPattern> patterns,
  BuzzSequence? current,
  HapticDeviceProfile? profile,
  bool bandConnected = false,
  bool? allowLong,
  required Future<bool> Function(BuzzSequence) onPlay,
  required VoidCallback onDefault,
  required ValueChanged<BuzzSequence> onChoose,
  required Future<SavedHapticPattern> Function(String name, BuzzSequence s)
  onSaveNew,
}) {
  final p = P.of(c);
  final names = [for (final s in patterns) s.name];

  void record() {
    if (!c.mounted) return;
    showBuzzPatternSheet(
      c,
      initial: current,
      bandConnected: bandConnected,
      onPlay: onPlay,
      profile: profile,
      allowLong: allowLong,
      patternNames: names,
      onSave: onChoose,
      onSaveNamed: (name, s) async {
        final saved = await onSaveNew(name, s);
        onChoose(saved.sequence);
      },
    );
  }

  void write() {
    final prof = profile;
    if (!c.mounted || prof == null) return;
    final nav = Navigator.of(c);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => HapticPatternEditorPage(
          profile: prof,
          onPlay: onPlay,
          allowLong: allowLong ?? Prefs.allowLongHaptics,
          existingNames: names,
          onSave: (name, s) async {
            nav.pop();
            final saved = await onSaveNew(name, s);
            onChoose(saved.sequence);
          },
        ),
      ),
    );
  }

  return showModalBottomSheet<void>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          key: const ValueKey('pattern-picker'),
          padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: S.x2),
                child: Text('Buzz pattern', style: F.head.copyWith(color: p.ink)),
              ),
              _PickerRow(
                key: const ValueKey('pattern-picker-default'),
                icon: LucideIcons.rotateCcw,
                title: 'Default',
                sub: 'The standard rhythm for this alert',
                onTap: () {
                  Navigator.of(sheet).pop();
                  onDefault();
                },
              ),
              for (final s in patterns)
                _PickerRow(
                  key: ValueKey('pattern-picker-row:${s.id}'),
                  icon: LucideIcons.waves,
                  title: s.name,
                  sub: s.sequence.notes ?? patternDetail(s.sequence),
                  selected:
                      current?.patternId != null &&
                      current!.patternId == s.id,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    onChoose(s.sequence.copyWith(patternId: s.id));
                  },
                ),
              _PickerRow(
                key: const ValueKey('pattern-picker-record'),
                icon: LucideIcons.hand,
                title: 'Record new…',
                sub: 'Tap out a rhythm',
                onTap: () {
                  Navigator.of(sheet).pop();
                  record();
                },
              ),
              if (profile != null)
                _PickerRow(
                  key: const ValueKey('pattern-picker-notes'),
                  icon: LucideIcons.music,
                  title: 'Write notes…',
                  sub: 'Notes and rests, with dynamics',
                  onTap: () {
                    Navigator.of(sheet).pop();
                    write();
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String title, sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: '$title. $sub${selected ? ', selected' : ''}',
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
              child: Icon(icon, size: 16, color: p.on(C.purple)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: F.body.copyWith(color: p.ink)),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: F.over.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(
                LucideIcons.check,
                key: const ValueKey('pattern-picker-selected'),
                size: 17,
                color: p.on(C.blue),
              ),
          ],
        ),
      ),
    );
  }
}
