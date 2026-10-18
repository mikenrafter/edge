// BUZZ PATTERN — pick the rhythm a notification buzzes the band with, by
// tapping it out.
//
// The control is one row per notification type (and one per app on the band
// relay); the sheet is where the rhythm is made. Tapping records offsets with
// [BuzzRecorder], the phone buzzes once on the first tap so the finger has
// feedback, and when the take ends it plays back on the band if one is
// connected. A band that is not connected still lets the take be saved — the
// playback is a preview, not a condition.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../haptics/haptic_compiler.dart';
import '../../haptics/haptic_profile.dart';
import '../../haptics/tap_notes.dart';
import '../../haptics/pattern_store.dart' show kPatternNameMax;
import '../../notify/buzz_sequence.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'haptic_pattern_editor.dart';
import 'haptic_plan_text.dart';
import 'profile.dart' show SetRow;

/// "1 buzz" / "3 buzzes": what the recording sheet says about the take being
/// made. An alert's row names its pattern instead (see [BuzzPatternRow]).
String buzzSummary(BuzzSequence s) =>
    s.length == 1 ? '1 buzz' : '${s.length} buzzes';

/// The row that opens the sheet, saying which pattern the alert plays by NAME
/// ("Three pulses", "Your: Morning nudge"), never by how many buzzes it has. A
/// rhythm whose pattern is not known reads "Custom". Disabled (present,
/// dimmed, inert) when the alert does not go to the band, rather than absent.
class BuzzPatternRow extends StatelessWidget {
  const BuzzPatternRow({
    super.key,
    required this.sequence,
    this.patternName,
    this.onTap,
    this.enabled = true,
  });

  final BuzzSequence sequence;

  /// The pattern's name; null when the screen does not know it.
  final String? patternName;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext c) {
    return SetRow(
      LucideIcons.waves,
      C.purple,
      'Buzz pattern',
      value: patternName ?? 'Custom',
      chevron: false,
      enabled: enabled,
      onTap: onTap,
    );
  }
}

/// Opens [BuzzPatternSheet] as a bottom sheet and closes it on Save. The sheet
/// is closed BEFORE [onSave] runs, so a callback that opens a dialog or a page
/// is not popped by the sheet's own close. [onSaveNamed] is the opposite: the
/// sheet stays open (the take is kept) until it completes, and closes only on
/// success; if it throws the sheet says so under the name.
Future<void> showBuzzPatternSheet(
  BuildContext c, {
  BuzzSequence? initial,
  bool bandConnected = false,
  Future<bool> Function(BuzzSequence)? onPlay,
  HapticDeviceProfile? profile,
  bool? allowLong,
  Iterable<String>? patternNames,
  FutureOr<void> Function(String name, BuzzSequence s)? onSaveNamed,
  FutureOr<void> Function(String name, BuzzSequence s)? onSaveAsNotes,
  Iterable<String>? notesNames,
  String? notesName,
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
        allowLong: allowLong,
        patternNames: patternNames,
        notesNames: notesNames,
        notesName: notesName,
        onPhoneBuzz: HapticFeedback.heavyImpact,
        onSave: (s) {
          _closeSheet(sheet);
          onSave(s);
        },
        onSaveNamed: onSaveNamed == null
            ? null
            : (name, s) async {
                await onSaveNamed(name, s);
                if (sheet.mounted) _closeSheet(sheet);
              },
        onSaveAsNotes: onSaveAsNotes == null
            ? null
            : (name, s) async {
                await onSaveAsNotes(name, s);
                if (sheet.mounted) _closeSheet(sheet);
              },
      ),
    ),
  );
}

// Closes the sheet's own route. With the notes editor open above it the sheet
// is not the top route, so a plain pop would close the editor instead.
void _closeSheet(BuildContext sheet) {
  if (!sheet.mounted) return;
  final route = ModalRoute.of(sheet);
  if (route == null || !route.isActive) return;
  final nav = Navigator.of(sheet);
  if (route.isCurrent) {
    nav.pop();
  } else {
    nav.removeRoute(route);
  }
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
    this.allowLong,
    this.patternNames,
    this.onSaveNamed,
    this.onSaveAsNotes,
    this.notesNames,
    this.notesName,
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

  /// Lift the 10 s runtime cap. Null reads the "Allow long sequences"
  /// setting.
  final bool? allowLong;

  /// The names in the pattern store. Non-null offers "Save to my
  /// patterns" (off) with a name field; only the pattern picker passes it.
  final Iterable<String>? patternNames;

  /// Called instead of [onSave] when the take is saved under a name.
  final FutureOr<void> Function(String name, BuzzSequence s)? onSaveNamed;

  /// Called with the name and notes when the take was opened in the
  /// notes editor ("Edit as notes") and saved there. Without it the editor
  /// saves through [onSaveNamed], else [onSave].
  final FutureOr<void> Function(String name, BuzzSequence s)? onSaveAsNotes;

  /// The names the notes editor refuses as taken; [patternNames] when null.
  final Iterable<String>? notesNames;

  /// The name of the pattern being re-recorded, so the editor does not ask.
  final String? notesName;

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

  bool _toPatterns = false;
  final _name = TextEditingController();
  String? _nameError;
  bool _savingNamed = false;

  DateTime _recordTime() {
    _pressClock.start();
    return DateTime.fromMillisecondsSinceEpoch(0).add(_pressClock.elapsed);
  }

  @override
  void dispose() {
    _rec.dispose();
    _name.dispose();
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

  bool get _allowLong => widget.allowLong ?? Prefs.allowLongHaptics;

  /// The plan for a take on a band with a profile. Null without a profile, or
  /// when the take runs over the cap.
  HapticPlan? _planFor(BuzzSequence result) {
    final profile = widget.profile;
    if (profile == null) return null;
    return planForTaps(
      result,
      profile,
      maxRuntime: maxRuntimeFor(allowLong: _allowLong),
    );
  }

  /// Save: under a name when "Save to my patterns" is on and the name is good,
  /// else as the take.
  Future<void> _save(BuzzSequence result, HapticPlan? plan) async {
    final seq = _toSave(result, plan);
    final names = widget.patternNames;
    if (!_toPatterns || names == null || widget.onSaveNamed == null) {
      widget.onSave?.call(seq);
      return;
    }
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Give it a name.');
    } else if (name.length > kPatternNameMax) {
      setState(() => _nameError = 'Keep it under $kPatternNameMax characters.');
    } else if (names.any((n) => n.toLowerCase() == name.toLowerCase())) {
      setState(() => _nameError = 'A pattern with that name already exists.');
    } else if (!_savingNamed) {
      _savingNamed = true;
      try {
        await widget.onSaveNamed!(name, seq);
      } catch (_) {
        if (mounted) {
          setState(() => _nameError = 'Could not save that pattern. Try again.');
        }
      } finally {
        _savingNamed = false;
      }
    }
  }

  /// What was saved: the take, and on a band with a profile
  /// also the notes it was heard as, the profile and the plan compiled for
  /// them, so the rule plays the same later whatever the vocabulary becomes.
  BuzzSequence _toSave(BuzzSequence result, HapticPlan? plan) {
    final s = result;
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
      bakedRuntimeMs: plan.runtimeMs,
    );
  }

  /// Opens the take in the advanced editor as `*` notes on "Prioritize
  /// rhythm" (taps carry no loudness). Saving there goes through
  /// [BuzzPatternSheet.onSaveAsNotes] (else [onSaveNamed], else [onSave]) and
  /// closes the editor; a failure stays in the editor.
  void _editAsNotes(BuzzSequence result, HapticPlan? plan) {
    final profile = widget.profile;
    if (profile == null) return;
    final seed = plan != null
        ? _toSave(result, plan)
        : result.copyWith(
            notes: notesFromTaps(result, unitMs: profile.unitMs).join(' '),
            profileId: profile.id,
            profileVersion: profile.version,
          );
    final nav = Navigator.of(context);
    final onSave = widget.onSave;
    final named = widget.onSaveAsNotes ?? widget.onSaveNamed;
    late final MaterialPageRoute<void> route;
    route = MaterialPageRoute<void>(
      builder: (_) => HapticPatternEditorPage(
        initial: seed,
        name: widget.notesName,
        profile: profile,
        onPlay: widget.onPlay ?? (_) async => false,
        allowLong: _allowLong,
        existingNames: widget.notesNames ?? widget.patternNames ?? const [],
        onSave: (name, s) async {
          if (named != null) {
            await named(name, s);
          } else {
            onSave?.call(s);
          }
          if (route.isActive) nav.pop();
        },
      ),
    );
    nav.push(route);
  }

  /// On a band with a profile: the notes the take was heard as and one calm
  /// line about what the band will play.
  List<Widget> _heard(P p, BuzzSequence result, HapticPlan? plan) {
    final profile = widget.profile;
    if (profile == null) return const [];
    final s = result;
    return [
      const SizedBox(height: S.x2),
      Text(
        notesFromTaps(s, unitMs: profile.unitMs).join(' '),
        style: F.cap.copyWith(color: p.ink2),
      ),
      ...hapticPlanLines(p, plan, tooLong: !_allowLong),
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
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        S.x4,
        S.x2,
        S.x4,
        S.x4 + MediaQuery.viewInsetsOf(c).bottom,
      ),
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
            if (widget.patternNames != null) ...[
              const SizedBox(height: S.x2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Save to my patterns',
                      style: F.body.copyWith(color: p.ink),
                    ),
                  ),
                  Switch(
                    key: const ValueKey('buzz-save-to-patterns'),
                    value: _toPatterns,
                    onChanged: (v) => setState(() {
                      _toPatterns = v;
                      _nameError = null;
                    }),
                  ),
                ],
              ),
              if (_toPatterns)
                TextField(
                  key: const ValueKey('pattern-name-field'),
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Pattern name',
                    errorText: _nameError,
                  ),
                ),
            ],
            const SizedBox(height: S.x3),
            BigButton(
              'Save',
              onTap: canSave ? () => _save(result, plan) : null,
            ),
            if (widget.profile != null) ...[
              const SizedBox(height: S.x2),
              BigButton(
                'Edit as notes',
                key: const ValueKey('buzz-edit-notes'),
                soft: true,
                color: C.purple,
                onTap: () => _editAsNotes(result, plan),
              ),
            ],
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
