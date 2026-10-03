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
// caller closes the page once the pattern is stored, and a failed save leaves
// the page open with the pattern kept.

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/hardware_probes.dart';
import '../../gestures/pattern_transcript.dart';
import '../../haptics/haptic_compiler.dart';
import '../../haptics/haptic_player.dart' show HapticPlayStart;
import '../../haptics/haptic_profile.dart';
import '../../haptics/pattern_store.dart' show kPatternNameMax;
import '../../haptics/tap_notes.dart';
import '../../notify/buzz_sequence.dart';
import '../ui2.dart';
import 'haptic_plan_text.dart';
import 'pattern_notation.dart';
import 'tap_take_pad.dart';

/// The lengths with a button of their own; the Dot makes 2, 4, 8 into 3, 6, 12.
const List<int> _buttonLengths = [1, 2, 4, 8];

/// A preview that also says when each command starts playing on the band
/// (AppState.previewBuzzSequence). The editor's [HapticPatternEditorPage.onPlay]
/// may be one: when it is, the wheel follows the playback; a plain
/// `Future<bool> Function(BuzzSequence)` plays without following.
typedef FollowingPreview = Future<bool> Function(
  BuzzSequence s, {
  void Function(HapticPlayStart)? onStart,
});

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

  /// Plays a sequence on the band; true when it was sent. A [FollowingPreview]
  /// also reports when each command starts, and the editor then marches a
  /// playhead through the entries.
  final Future<bool> Function(BuzzSequence) onPlay;

  /// Called with the name and the sequence to store. The page stays open
  /// until it completes; if it throws, the page says the save failed and keeps
  /// the pattern for another try.
  final FutureOr<void> Function(String name, BuzzSequence s) onSave;

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
  late HapticPriority _priority =
      widget.initial?.priority ?? HapticPriority.rhythm;
  HapticPlan? _plan;
  bool _tooLong = false;
  bool _playing = false;
  bool? _played;
  bool _saved = false;
  bool _saving = false;
  bool _saveFailed = false;

  // The name last asked for, offered again after a failed save.
  String? _lastName;

  // Following a play: the playhead marches through the entries from each
  // command's start, as the probe's does. Timers run from the band's start
  // signal, so a held preview shows nothing. A tap or a scroll cancels, and
  // the cursor is never moved.
  final List<Timer> _march = [];
  bool _marching = false;
  int? _head;
  // Which play's start signals count; a new play or a cancel moves it on.
  int _run = 0;
  List<HapticStep> _runSteps = const [];
  PatternTranscript _runEntries = PatternTranscript(const []);
  int _runUnitMs = PatternEntrySession.defaultUnitMs;

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
    _clearMarch();
    _wheel.dispose();
    super.dispose();
  }

  void _clearMarch() {
    for (final t in _march) {
      t.cancel();
    }
    _march.clear();
  }

  /// Stop following (and ignore the rest of the play's start signals). The
  /// caller redraws.
  void _stopMarch() {
    _clearMarch();
    _marching = false;
    _head = null;
    _run++;
  }

  /// A command of the play [run] started at [st].at: put the playhead where
  /// that command starts, allowing for time already gone, and schedule the
  /// entries up to the next command's start (or to the end after the last).
  /// Every start signal re-anchors, so gaps that vary on the band do not
  /// accumulate.
  void _onStart(int run, HapticPlayStart st) {
    if (!mounted || run != _run) return;
    if (st.command < 0 || st.command >= _runSteps.length) return;
    final unit = _runUnitMs;
    final base = _runSteps[st.command].startUnit * unit;
    final last = st.command == _runSteps.length - 1;
    final until = last ? null : _runSteps[st.command + 1].startUnit * unit;
    final gone = clock.now().difference(st.at).inMilliseconds;
    _clearMarch();
    _marching = true;
    int? now;
    for (final e in PatternEntrySession.march(_runEntries, unit, 0)) {
      if (e.endMs <= base) continue;
      if (until != null && e.startMs >= until) break;
      final rel = e.startMs - base - gone;
      if (rel <= 0) {
        if (e.endMs - base - gone > 0) now = e.index;
      } else {
        _march.add(Timer(patternMs(rel), () => _playhead(e.index)));
      }
    }
    if (until == null) {
      final end = PatternEntrySession.march(_runEntries, unit, 0).last.endMs;
      _march.add(Timer(patternMs(math.max(0, end - base - gone)), _marchEnded));
    } else {
      // The next command never started (the band swallowed it, or the play
      // died): do not hold the playhead for ever.
      _march.add(Timer(
        patternMs(math.max(0, until - base - gone) + 2000),
        () {
          if (!mounted) return;
          setState(() {
            _stopMarch();
          });
          _syncWheel();
        },
      ));
    }
    setState(() => _head = now);
    if (now != null) _glideTo(now);
  }

  void _playhead(int i) {
    if (!mounted || !_marching) return;
    setState(() => _head = i);
    _glideTo(i);
  }

  void _marchEnded() {
    if (!mounted || !_marching) return;
    setState(() {
      _marching = false;
      _head = null;
    });
    _glideTo(_s.cursor);
  }

  void _glideTo(int item) {
    if (!_wheel.hasClients) return;
    unawaited(
      _wheel.animateToItem(
        item,
        duration: motion(context, Motion.fast),
        curve: Curves.easeOut,
      ),
    );
  }

  /// The plan for the entries as they are now, and whether it is missing only
  /// because of the cap.
  void _recompute() {
    final entries = _entries;
    final p = widget.profile;
    final cap = _cap?.inMilliseconds;
    _plan = entries.any((e) => e.note)
        ? compile(
            entries,
            p,
            extended: _extended,
            priority: _priority,
            maxRuntimeMs: cap,
          )
        : null;
    _tooLong = _plan == null &&
        cap != null &&
        entries.any((e) => e.note) &&
        compile(entries, p, extended: _extended, priority: _priority) != null;
  }

  void _edit(void Function() change) {
    setState(() {
      _stopMarch();
      change();
      _played = null;
      _saved = false;
      _saveFailed = false;
      _recompute();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncWheel());
  }

  void _syncWheel() {
    if (!mounted || !_wheel.hasClients || _marching) return;
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
      priority: _priority,
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
      bakedRuntimeMs: plan.runtimeMs,
    );
  }

  Future<void> _play() async {
    final seq = _sequence();
    if (seq == null || _playing) return;
    setState(() {
      _stopMarch();
      _playing = true;
      _played = null;
    });
    final run = _run;
    _runSteps = _plan!.steps;
    _runEntries = _s.active;
    _runUnitMs = widget.profile.unitMs;
    var ok = false;
    try {
      final play = widget.onPlay;
      ok = await (play is FollowingPreview
          ? play(seq, onStart: (st) => _onStart(run, st))
          : play(seq));
    } catch (_) {
      ok = false;
    } finally {
      if (mounted) {
        setState(() {
          if (!ok && run == _run) _stopMarch();
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
    if (seq == null || _saving) return;
    var name = widget.name;
    if (name == null) {
      name = await showDialog<String>(
        context: context,
        builder: (_) => PatternNameDialog(
          taken: widget.existingNames,
          initial: _lastName,
        ),
      );
      if (name == null || !mounted) return;
      _lastName = name;
    }
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    var ok = true;
    try {
      await widget.onSave(name, seq);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saveFailed = !ok;
      _saved = ok;
    });
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
                    // The wearer takes the wheel: stop following.
                    if (_userScrolling && (_marching || _head != null)) {
                      setState(_stopMarch);
                    }
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
                        playing: i == _head,
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
                          if (_saveFailed)
                            Text(
                              'Could not save that pattern. Try again.',
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
                    key: const ValueKey('pattern-editor-priority'),
                    children: [
                      for (final o in HapticPriority.values) ...[
                        if (o != HapticPriority.values.first)
                          const SizedBox(width: S.x2),
                        Expanded(
                          child: _PriorityOption(
                            key: ValueKey('pattern-editor-priority-${o.name}'),
                            label: o == HapticPriority.rhythm
                                ? 'Prioritize rhythm'
                                : 'Prioritize dynamics',
                            selected: _priority == o,
                            onTap: () => _edit(() => _priority = o),
                          ),
                        ),
                      ],
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
    return hapticPlanLines(p, _plan, tooLong: _tooLong, written: _entries);
  }
}

/// One side of the rhythm / dynamics toggle. The chosen one is outlined and
/// washed, like the dynamics buttons.
class _PriorityOption extends StatelessWidget {
  const _PriorityOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: S.x1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? p.wash(C.blue) : p.card,
            borderRadius: R.rMd,
            border: Border.all(
              color: selected ? C.blue : p.ink3,
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: F.cap.copyWith(
              color: p.ink,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for a name. Pops with the trimmed name, or null on Cancel; an empty,
/// taken or over-long ([kPatternNameMax]) name keeps the dialog open and says
/// why.
class PatternNameDialog extends StatefulWidget {
  const PatternNameDialog({
    super.key,
    required this.taken,
    this.initial,
    this.message,
  });

  /// Names that may not be used (compared without regard to case). A rename
  /// leaves the pattern's own name out, so only its case can change.
  final Iterable<String> taken;

  /// The text the field starts with, for a rename.
  final String? initial;

  /// Shown under the field from the start, for a name that was refused after
  /// the dialog closed (the save failed).
  final String? message;

  @override
  State<PatternNameDialog> createState() => _PatternNameDialogState();
}

class _PatternNameDialogState extends State<PatternNameDialog> {
  late final _field = TextEditingController(text: widget.initial);
  late String? _error = widget.message;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _ok() {
    final name = _field.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give it a name.');
    } else if (name.length > kPatternNameMax) {
      setState(() => _error = 'Keep it under $kPatternNameMax characters.');
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
