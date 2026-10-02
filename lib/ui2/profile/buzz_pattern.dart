// BUZZ PATTERN — pick the rhythm a notification buzzes the band with, by
// tapping it out.
//
// The control is one row per notification type (and one per app on the band
// relay); the sheet is where the rhythm is made. Tapping records offsets with
// [BuzzRecorder], the phone buzzes once on the first tap so the finger has
// feedback, and when the take ends it plays back on the band if one is
// connected. A band that is not connected still lets the take be saved — the
// playback is a preview, not a condition.

import 'package:flutter/material.dart';
import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../notify/buzz_sequence.dart';
import '../ui2.dart';
import 'profile.dart' show SetRow;

/// "1 buzz" / "3 buzzes" — what the row says about the rhythm behind it.
String buzzSummary(BuzzSequence s) =>
    s.length == 1 ? '1 buzz' : '${s.length} buzzes';

/// The row that opens the sheet. Disabled (present, dimmed, inert) when the
/// alert does not go to the band, rather than absent.
class BuzzPatternRow extends StatelessWidget {
  const BuzzPatternRow({
    super.key,
    required this.sequence,
    this.onTap,
    this.enabled = true,
  });

  final BuzzSequence sequence;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext c) {
    return SetRow(
      LucideIcons.waves,
      C.purple,
      'Buzz pattern',
      value: buzzSummary(sequence),
      chevron: false,
      enabled: enabled,
      onTap: onTap,
    );
  }
}

/// Opens [BuzzPatternSheet] as a bottom sheet and closes it on Save.
Future<void> showBuzzPatternSheet(
  BuildContext c, {
  BuzzSequence? initial,
  bool bandConnected = false,
  Future<bool> Function(BuzzSequence)? onPlay,
  required ValueChanged<BuzzSequence> onSave,
}) {
  final p = P.of(c);
  return showModalBottomSheet<void>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: BuzzPatternSheet(
        initial: initial,
        bandConnected: bandConnected,
        onPlay: onPlay,
        onPhoneBuzz: HapticFeedback.heavyImpact,
        onSave: (s) {
          onSave(s);
          Navigator.of(sheet).pop();
        },
      ),
    ),
  );
}

class BuzzPatternSheet extends StatefulWidget {
  const BuzzPatternSheet({
    super.key,
    this.initial,
    this.bandConnected = false,
    this.onPlay,
    this.onSave,
    this.onPhoneBuzz,
  });

  /// The rhythm in use now, shown above the button. Null shows nothing.
  final BuzzSequence? initial;
  final bool bandConnected;

  /// Plays a finished take on the band. Only called when [bandConnected].
  final Future<bool> Function(BuzzSequence)? onPlay;
  final ValueChanged<BuzzSequence>? onSave;

  /// One phone buzz when the take starts.
  final VoidCallback? onPhoneBuzz;

  @override
  State<BuzzPatternSheet> createState() => _BuzzPatternSheetState();
}

class _BuzzPatternSheetState extends State<BuzzPatternSheet> {
  late final BuzzRecorder _rec = BuzzRecorder(
    onStart: () {
      widget.onPhoneBuzz?.call();
      if (mounted) setState(() {});
    },
    onDone: _done,
  );

  /// null = not played, true/false = the band's answer to the last playback.
  bool? _played;
  late final Stopwatch _pressClock = clock.stopwatch();

  DateTime _recordTime() {
    _pressClock.start();
    return DateTime.fromMillisecondsSinceEpoch(0).add(_pressClock.elapsed);
  }

  @override
  void dispose() {
    _rec.dispose();
    super.dispose();
  }

  Future<void> _done(BuzzSequence seq) async {
    if (!mounted) return;
    setState(() => _played = null);
    final play = widget.onPlay;
    if (!widget.bandConnected || play == null) return;
    bool ok;
    try {
      ok = await play(seq);
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _played = ok);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final result = _rec.result;
    final initial = widget.initial;
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (initial != null && result == null && !_rec.recording)
            Padding(
              padding: const EdgeInsets.only(bottom: S.x3),
              child: Text(
                'Now: ${buzzSummary(initial)}',
                style: F.body.copyWith(color: p.ink),
              ),
            ),
          Text(
            'Tap or hold the rhythm you want. It ends 2 seconds after release, or '
            'at ${BuzzSequence.maxBuzzes} taps.',
            style: F.cap.copyWith(color: p.ink2),
          ),
          const SizedBox(height: S.x1),
          // The one claim worth making where the user is: playback is a live
          // write from the phone, not something the band stores.
          Text(
            widget.bandConnected
                ? 'Plays back on the band when you stop. The phone must be '
                      'connected to the band for this rhythm to buzz.'
                : 'The band is not connected, so there is no playback. The '
                      'phone must be connected to the band for this rhythm to '
                      'buzz.',
            style: F.over.copyWith(color: p.ink3),
          ),
          Text(
            'On MG, long holds use a repeated waveform, so buzz lengths '
            'approximate your presses. Long holds are unsupported on 4.0.',
            style: F.over.copyWith(color: p.ink3),
          ),
          const SizedBox(height: S.x4),
          if (result == null)
            BigButton(
              'Tap your pattern',
              icon: LucideIcons.hand,
              color: _rec.recording ? C.orange : C.blue,
              onTap: () => _rec.tap(at: _recordTime()),
              onPressStart: () => _rec.pressStart(at: _recordTime()),
              onPressEnd: () => _rec.pressEnd(at: _recordTime()),
              onPressCancel: () {
                _rec.pressCancel(at: _recordTime());
                if (mounted) setState(() {});
              },
            )
          else ...[
            Text(
              '${buzzSummary(result)} recorded'
              '${_played == null
                  ? ''
                  : _played!
                  ? '. Played on the band.'
                  : '. The band did not play it.'}',
              style: F.body.copyWith(color: p.ink),
            ),
            const SizedBox(height: S.x3),
            BigButton('Save', onTap: () => widget.onSave?.call(result)),
            const SizedBox(height: S.x2),
            BigButton(
              'Record again',
              soft: true,
              color: C.blue,
              onTap: () => setState(() {
                _rec.reset();
                _played = null;
              }),
            ),
          ],
        ],
      ),
    );
  }
}
