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

import '../../haptics/haptic_compiler.dart';
import '../../haptics/haptic_profile.dart';
import '../../haptics/tap_notes.dart';
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
  HapticDeviceProfile? profile,
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
        profile: profile,
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
    this.profile,
  });

  /// The rhythm in use now, shown above the button. Null shows nothing.
  final BuzzSequence? initial;
  final bool bandConnected;

  /// Plays a finished take on the band. Only called when [bandConnected].
  final Future<bool> Function(BuzzSequence)? onPlay;
  final ValueChanged<BuzzSequence>? onSave;

  /// One phone buzz when the take starts.
  final VoidCallback? onPhoneBuzz;

  /// The connected band's measured haptic vocabulary (a WHOOP MG). When given,
  /// a take also shows the notes it heard and the commands planned for them;
  /// null keeps the text-only sheet.
  final HapticDeviceProfile? profile;

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

  /// The rule's extended haptics opset setting; carried by what is played and
  /// saved, and kept across "Record again".
  late bool _extended = widget.initial?.extended ?? false;
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
      ok = await play(seq.copyWith(extended: _extended));
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _played = ok);
  }

  /// The plan for a take on a band with a profile, with the opset switch as
  /// it is now. Null without a profile, or when the take runs over the cap.
  HapticPlan? _planFor(BuzzSequence result) {
    final profile = widget.profile;
    if (profile == null) return null;
    return planForTaps(result.copyWith(extended: _extended), profile);
  }

  /// "May not play exactly as written. The band plays: N4mf R1 N4mf to ...".
  String _notExactLine(HapticPlan plan) {
    final lo = plan.feltMin.join(' ');
    final hi = plan.feltMax.join(' ');
    return 'May not play exactly as written. The band plays: '
        '${lo == hi ? lo : '$lo to $hi'}.';
  }

  /// What was saved: the take with the switch, and on a band with a profile
  /// also the notes it was heard as, the profile and the plan compiled for
  /// them, so the rule plays the same later whatever the vocabulary becomes.
  BuzzSequence _toSave(BuzzSequence result, HapticPlan? plan) {
    final s = result.copyWith(extended: _extended);
    final profile = widget.profile;
    if (profile == null || plan == null) return s;
    return s.copyWith(
      notes: notesFromTaps(s, unitMs: profile.unitMs).join(' '),
      profileId: profile.id,
      profileVersion: profile.version,
      bakedSteps: [
        for (final st in plan.steps)
          BakedStep(
            effects: st.phrase.effects,
            loop: st.phrase.loop,
            delayMs: st.delayMs,
          ),
      ],
    );
  }

  /// On a band with a profile: the notes the take was heard as and one calm
  /// line about what the band will play, recompiled whenever the switch
  /// changes.
  List<Widget> _heard(P p, BuzzSequence result, HapticPlan? plan) {
    final profile = widget.profile;
    if (profile == null) return const [];
    final s = result.copyWith(extended: _extended);
    return [
      const SizedBox(height: S.x2),
      Text(
        notesFromTaps(s, unitMs: profile.unitMs).join(' '),
        style: F.cap.copyWith(color: p.ink2),
      ),
      if (plan == null)
        Text(
          'Too long for the band: keep it under '
          '${kMaxHapticRuntime.inSeconds} seconds.',
          style: F.cap.copyWith(color: p.ink2),
        )
      else ...[
        Text(plan.summary, style: F.cap.copyWith(color: p.ink2)),
        if (plan.exact)
          Text('Plays as written.', style: F.cap.copyWith(color: p.ink2))
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info, size: 14, color: p.ink3),
              const SizedBox(width: S.x1),
              Expanded(
                child: Text(
                  _notExactLine(plan),
                  style: F.cap.copyWith(color: p.ink3),
                ),
              ),
            ],
          ),
        if (plan.usesUnstable)
          Text(
            'Extended haptics: timings may vary unexpectedly.',
            style: F.cap.copyWith(color: p.ink3),
          ),
        if (plan.steps.length > 1)
          Text(
            'Pauses between buzzes can vary a little.',
            style: F.cap.copyWith(color: p.ink3),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final result = _rec.result;
    final initial = widget.initial;
    final plan = result == null ? null : _planFor(result);
    // With a profile a take the band cannot play within the cap is not saved.
    final canSave = widget.profile == null || plan != null;
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
          if (widget.profile == null)
            Text(
              'On MG, a long press plays the buzz twice, so lengths are close, not '
              'exact. On 4.0 a long press plays as a short buzz.',
              style: F.over.copyWith(color: p.ink3),
            ),
          const SizedBox(height: S.x3),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Extended haptics opset',
                      style: F.body.copyWith(color: p.ink),
                    ),
                    Text(
                      'Timings may vary unexpectedly.',
                      style: F.over.copyWith(color: p.ink3),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const ValueKey('buzz-extended'),
                value: _extended,
                onChanged: (v) => setState(() => _extended = v),
              ),
            ],
          ),
          const SizedBox(height: S.x3),
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
                  : '. The phone could not send it to the band.'}',
              style: F.body.copyWith(color: p.ink),
            ),
            ..._heard(p, result, plan),
            const SizedBox(height: S.x3),
            BigButton(
              'Save',
              onTap: canSave
                  ? () => widget.onSave?.call(_toSave(result, plan))
                  : null,
            ),
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
