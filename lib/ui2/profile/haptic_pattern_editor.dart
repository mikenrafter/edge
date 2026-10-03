// Advanced notes editor (8AD): write a haptic pattern as notes and rests.
//
// The entry model is the pattern probe's: a wheel of entries, a Note/Rest
// toggle that alternates after every tap and can be overridden, the four
// lengths 16th, eighth, quarter and half with a one-shot Dot, six dynamics
// that stick until changed, and Delete. There is one rendition, no tests, no
// metronome and no limit pill. The tempo is the band profile's unit.
//
// Under the wheel the editor says what the band plays for the notes as they
// are now (the 8AC wording, recomputed on every edit) and has the extended
// haptics opset switch. Play sends exactly what is on the page to the band.
// "Start from taps" fills the notes from a tapped rhythm. Save asks for a name
// when the pattern is new, bakes the plan and hands the result to [onSave]; the
// caller closes the page.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/hardware_probes.dart';
import '../../gestures/pattern_transcript.dart';
import '../../haptics/haptic_compiler.dart';
import '../../haptics/haptic_profile.dart';
import '../../haptics/tap_notes.dart';
import '../../notify/buzz_sequence.dart';
import '../ui2.dart';
import 'haptic_plan_text.dart';
import 'pattern_notation.dart';
import 'tap_take_pad.dart';

/// The lengths with a button of their own; the Dot makes 2, 4, 8 into 3, 6, 12.
const List<int> _buttonLengths = [1, 2, 4, 8];

class HapticPatternEditorPage extends StatefulWidget {
  const HapticPatternEditorPage({
    super.key,
    this.initial,
    this.name,
    required this.profile,
    required this.onPlay,
    required this.onSave,
    this.allowLong = false,
    this.existingNames = const [],
  });

  /// The pattern to edit; its notes are the starting entries. Null, or one
  /// without notes, starts empty.
  final BuzzSequence? initial;

  /// The name of the pattern being edited. Null is a new pattern: Save asks.
  final String? name;
  final HapticDeviceProfile profile;

  /// Plays a sequence on the band; true when it was sent.
  final Future<bool> Function(BuzzSequence) onPlay;

  /// Called with the name and the sequence to store.
  final void Function(String name, BuzzSequence s) onSave;

  /// Lift the 10 s runtime cap.
  final bool allowLong;

  /// The names already in the store, so a new name can be refused as a
  /// duplicate (compared without regard to case).
  final Iterable<String> existingNames;

  @override
  State<HapticPatternEditorPage> createState() => _HapticPatternEditorState();
}

class _HapticPatternEditorState extends State<HapticPatternEditorPage> {
  // The probe's entry model, with one throwaway test: the session owns the
  // cursor, the toggle, the sticky dynamic and the Dot.
  late final PatternEntrySession _s = PatternEntrySession([
    PatternProbe.defaultTests.first,
  ]);
  late final FixedExtentScrollController _wheel;
  // True while the wearer's finger moves the wheel; only then does it move the
  // cursor, not a jump when the list changes length.
  bool _userScrolling = false;

  late bool _extended = widget.initial?.extended ?? false;
  HapticPlan? _plan;
  bool _tooLong = false;
  bool _playing = false;
  bool? _played;
  bool _saved = false;

  List<PatternEntry> get _entries => _s.active.entries;

  Duration? get _cap => maxRuntimeFor(allowLong: widget.allowLong);

  @override
  void initState() {
    super.initState();
    final notes = widget.initial?.notes;
    if (notes != null) {
      try {
        _s.setActive(PatternTranscript.parseCode(notes).entries);
      } on Object {
        // Notes that do not parse start an empty editor.
      }
    }
    _wheel = FixedExtentScrollController(initialItem: _s.cursor);
    _recompute();
  }

  @override
  void dispose() {
    _wheel.dispose();
    super.dispose();
  }

  /// The plan for the entries as they are now, and whether it is missing only
  /// because of the cap.
  void _recompute() {
    final entries = _entries;
    final p = widget.profile;
    final cap = _cap?.inMilliseconds;
    _plan = entries.any((e) => e.note)
        ? compile(entries, p, extended: _extended, maxRuntimeMs: cap)
        : null;
    _tooLong = _plan == null &&
        cap != null &&
        entries.any((e) => e.note) &&
        compile(entries, p, extended: _extended) != null;
  }

  void _edit(void Function() change) {
    setState(() {
      change();
      _played = null;
      _saved = false;
      _recompute();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncWheel());
  }

  void _syncWheel() {
    if (!mounted || !_wheel.hasClients) return;
    if (_wheel.selectedItem == _s.cursor) return;
    _wheel.jumpToItem(_s.cursor);
  }

  void _scrolled(int item) {
    if (!_userScrolling || item == _s.cursor) return;
    _edit(() => _s.moveCursor(item - _s.cursor));
  }

  /// What Play and Save use: the notes, the profile and the plan baked for
  /// them, the switch, and the rhythm of the notes. Null while there is no
  /// plan to bake.
  BuzzSequence? _sequence() {
    final plan = _plan;
    if (plan == null) return null;
    final p = widget.profile;
    return tapsFromNotes(_entries, unitMs: p.unitMs).copyWith(
      extended: _extended,
      notes: _s.active.code,
      profileId: p.id,
      profileVersion: p.version,
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

  Future<void> _play() async {
    final seq = _sequence();
    if (seq == null || _playing) return;
    setState(() {
      _playing = true;
      _played = null;
    });
    var ok = false;
    try {
      ok = await widget.onPlay(seq);
    } catch (_) {
      ok = false;
    } finally {
      if (mounted) {
        setState(() {
          _playing = false;
          _played = ok;
        });
      }
    }
  }

  Future<void> _fromTaps() async {
    final take = await takeTapsForPattern(
      context,
      hasNotes: _entries.isNotEmpty,
      padKey: const ValueKey('pattern-editor-tap-pad'),
    );
    if (take == null || !mounted) return;
    _edit(
      () => _s.setActive(notesFromTaps(take, unitMs: widget.profile.unitMs)),
    );
  }

  Future<void> _save() async {
    final seq = _sequence();
    if (seq == null) return;
    var name = widget.name;
    if (name == null) {
      name = await showDialog<String>(
        context: context,
        builder: (_) => PatternNameDialog(taken: widget.existingNames),
      );
      if (name == null || !mounted) return;
    }
    widget.onSave(name, seq);
    if (mounted) setState(() => _saved = true);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final noteNext = _s.nextIsNote;
    final dot = _s.dotNext;
    final active = _s.active;
    final canGo = _plan != null;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(
                widget.name ?? 'New pattern',
                trailingWidth: 72,
                trailing: Pressable(
                  key: const ValueKey('pattern-editor-save'),
                  onTap: canGo ? _save : null,
                  semanticLabel: 'Save',
                  child: Text(
                    'Save',
                    style: F.body.copyWith(
                      color: canGo ? p.on(C.blue) : p.ink3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: Row(
                children: [
                  Expanded(
                    child: active.length == 0
                        ? Text(
                            'Pick Note or Rest, then a length.',
                            style: F.cap.copyWith(color: p.ink2),
                          )
                        : Text(
                            active.code,
                            key: const ValueKey('pattern-editor-code'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: F.cap.copyWith(color: p.ink2),
                          ),
                  ),
                  Pressable(
                    key: const ValueKey('pattern-editor-from-taps'),
                    onTap: _fromTaps,
                    semanticLabel: 'Start from taps',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.hand, size: 16, color: p.on(C.blue)),
                        const SizedBox(width: S.x1),
                        Text(
                          'From taps',
                          style: F.cap.copyWith(
                            color: p.on(C.blue),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is ScrollStartNotification) {
                    _userScrolling = n.dragDetails != null;
                  } else if (n is ScrollEndNotification) {
                    _userScrolling = false;
                  }
                  return false;
                },
                child: ListWheelScrollView(
                  key: const ValueKey('pattern-wheel'),
                  controller: _wheel,
                  itemExtent: kPatternRowExtent,
                  diameterRatio: 3,
                  physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: _scrolled,
                  children: [
                    for (var i = 0; i <= active.length; i++)
                      PatternEntryRow(
                        index: i,
                        note: i < active.length
                            ? active.entries[i].note
                            : noteNext,
                        length:
                            i < active.length ? active.entries[i].length : null,
                        dynamic: i < active.length
                            ? active.entries[i].dynamic
                            : null,
                        selected: i == _s.cursor,
                        playing: false,
                      ),
                  ],
                ),
              ),
            ),
            Container(
              color: p.card,
              padding: const EdgeInsets.fromLTRB(S.x4, S.x1, S.x4, S.x1),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 84),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ..._feedback(p),
                          if (_played == false)
                            Text(
                              'The phone could not send it to the band.',
                              style: F.cap.copyWith(color: p.on(C.red)),
                            ),
                          if (_saved)
                            Text(
                              'Saved.',
                              style: F.cap.copyWith(color: p.ink2),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Extended haptics opset',
                          style: F.body.copyWith(color: p.ink),
                        ),
                      ),
                      Switch(
                        key: const ValueKey('buzz-extended'),
                        value: _extended,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) => _edit(() => _extended = v),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      for (final d in PatternDynamic.values) ...[
                        if (d != PatternDynamic.values.first)
                          const SizedBox(width: S.x2),
                        Expanded(
                          child: PatternDynamicButton(
                            key: ValueKey('pattern-dyn-${d.name}'),
                            dynamic: d,
                            selected: d == _s.nextDynamic,
                            dim: !noteNext,
                            onTap: () => _edit(() => _s.setDynamic(d)),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: S.x1),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final n in _buttonLengths) ...[
                          Expanded(
                            child: PatternLengthButton(
                              key: ValueKey('pattern-len-$n'),
                              length: dot ? n * 3 ~/ 2 : n,
                              note: noteNext,
                              // A 16th has no dotted form.
                              onTap: dot && n == 1
                                  ? null
                                  : () => _edit(() => _s.tap(n)),
                            ),
                          ),
                          const SizedBox(width: S.x1),
                        ],
                        Expanded(
                          child: PatternDotButton(
                            key: const ValueKey('pattern-dot'),
                            selected: dot,
                            onTap: () => _edit(_s.toggleDot),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: S.x1),
                  Row(
                    children: [
                      Expanded(
                        child: BigButton(
                          noteNext ? 'Note' : 'Rest',
                          key: const ValueKey('pattern-kind'),
                          icon: noteNext
                              ? LucideIcons.music
                              : LucideIcons.pause,
                          soft: true,
                          color: noteNext ? C.blue : C.n400,
                          onTap: () => _edit(_s.toggleKind),
                        ),
                      ),
                      const SizedBox(width: S.x2),
                      Expanded(
                        child: BigButton(
                          'Delete',
                          key: const ValueKey('pattern-delete'),
                          icon: LucideIcons.delete,
                          soft: true,
                          color: C.red,
                          onTap: () => _edit(_s.delete),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: S.x1),
                  BigButton(
                    _playing ? 'Playing…' : 'Play',
                    key: const ValueKey('pattern-editor-play'),
                    icon: LucideIcons.vibrate,
                    color: C.blue,
                    onTap: canGo && !_playing ? _play : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the band plays for the entries now; nothing while there are none.
  List<Widget> _feedback(P p) {
    if (_entries.isEmpty) return const [];
    if (!_entries.any((e) => e.note)) {
      return [
        Text(
          'Add a note: a pattern of rests only plays nothing.',
          style: F.cap.copyWith(color: p.ink2),
        ),
      ];
    }
    return hapticPlanLines(p, _plan, tooLong: _tooLong);
  }
}

/// Asks for a name. Pops with the trimmed name, or null on Cancel; an empty or
/// taken name keeps the dialog open and says why.
class PatternNameDialog extends StatefulWidget {
  const PatternNameDialog({super.key, required this.taken, this.initial});

  /// Names that may not be used (compared without regard to case). A rename
  /// leaves the pattern's own name out, so only its case can change.
  final Iterable<String> taken;

  /// The text the field starts with, for a rename.
  final String? initial;

  @override
  State<PatternNameDialog> createState() => _PatternNameDialogState();
}

class _PatternNameDialogState extends State<PatternNameDialog> {
  late final _field = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _ok() {
    final name = _field.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give it a name.');
    } else if (widget.taken.any((t) => t.toLowerCase() == name.toLowerCase())) {
      setState(() => _error = 'A pattern with that name already exists.');
    } else {
      Navigator.of(context).pop(name);
    }
  }

  @override
  Widget build(BuildContext c) {
    return AlertDialog(
      title: const Text('Name this pattern'),
      content: TextField(
        key: const ValueKey('pattern-name-field'),
        controller: _field,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(errorText: _error),
        onSubmitted: (_) => _ok(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(c).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _ok, child: const Text('Save')),
      ],
    );
  }
}
