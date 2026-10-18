// A tap pad in a dialog: press, hold and release the rhythm, and
// two seconds after the last release (or at the eighth tap) the dialog closes
// with the take. Used by the notes editor's "Start from taps" and the pattern
// probe's "Tap what you felt". The recording is [BuzzRecorder]'s, the same as
// the buzz pattern sheet.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../notify/buzz_sequence.dart';
import '../ui2.dart';

/// Show the pad; the take, or null when it was dismissed first. The pad
/// itself carries [padKey]. A dialog rather than a sheet: it is in place from
/// its first frame, so a finger can land on it at once.
Future<BuzzSequence?> showTapTakePad(BuildContext c, {required Key padKey}) {
  return showDialog<BuzzSequence>(
    context: c,
    builder: (d) => Dialog(
      child: _TapTakePad(
        padKey: padKey,
        onTake: (s) => Navigator.of(d).pop(s),
      ),
    ),
  );
}

/// The take for a pattern that may already have notes: with [hasNotes] it asks
/// first (Replace or Cancel) and gives null on Cancel, then shows the pad.
Future<BuzzSequence?> takeTapsForPattern(
  BuildContext c, {
  required bool hasNotes,
  required Key padKey,
}) async {
  if (hasNotes) {
    final ok = await showDialog<bool>(
      context: c,
      builder: (d) => AlertDialog(
        title: const Text('Replace the notes?'),
        content: const Text('The notes you have now are replaced by the taps.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (ok != true || !c.mounted) return null;
  }
  return showTapTakePad(c, padKey: padKey);
}

class _TapTakePad extends StatefulWidget {
  const _TapTakePad({required this.padKey, required this.onTake});
  final Key padKey;
  final ValueChanged<BuzzSequence> onTake;

  @override
  State<_TapTakePad> createState() => _TapTakePadState();
}

class _TapTakePadState extends State<_TapTakePad> {
  late final BuzzRecorder _rec = BuzzRecorder(
    onStart: () {
      if (mounted) setState(() {});
    },
    onDone: (s) {
      if (mounted) widget.onTake(s);
    },
  );
  // Press times come off a stopwatch so a clock step cannot bend a hold.
  late final Stopwatch _pressClock = clock.stopwatch();

  DateTime _at() {
    _pressClock.start();
    return DateTime.fromMillisecondsSinceEpoch(0).add(_pressClock.elapsed);
  }

  @override
  void dispose() {
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tap or hold the rhythm you want. It ends 2 seconds after release, '
            'or at ${BuzzSequence.maxBuzzes} taps.',
            style: F.cap.copyWith(color: p.ink2),
          ),
          const SizedBox(height: S.x3),
          BigButton(
            'Tap your pattern',
            key: widget.padKey,
            icon: LucideIcons.hand,
            color: _rec.recording ? C.orange : C.blue,
            onTap: () => _rec.tap(at: _at()),
            onPressStart: () => _rec.pressStart(at: _at()),
            onPressEnd: () => _rec.pressEnd(at: _at()),
            onPressCancel: () {
              _rec.pressCancel(at: _at());
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}
