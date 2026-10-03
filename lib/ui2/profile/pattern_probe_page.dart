// Pattern probe page (8Y/8Z) — the transcriber the wearer taps.
//
// The band plays one test on demand. The wearer writes down what they felt in
// music terms: notes and rests of length 1 to 4. One unit is an eighth, so a
// length of 1, 2, 3, 4 is an eighth, quarter, dotted quarter, half, drawn as
// the matching note or rest symbol above one coloured dash per unit. A
// Note/Rest toggle flips after every tap and can be overridden, so two notes or
// two rests can sit next to each other. The entries sit on a wheel; the centred
// one is the cursor, so scrolling goes back and forward through them and a
// length button replaces the entry in the middle. Up to two renditions (A and
// B) per test, because the band may not play a pattern the same way twice. The
// footer stays on screen whatever the list does.
//
// A metronome dot steps once per unit (4/4: eight steps to a bar, a coloured
// step on each quarter and a rest between). When Play is pressed on a rendition
// that already has entries, a playhead marches through them on the same
// schedule, from the moment the first write landed plus the measured Bluetooth
// lead, and the dot restarts at that instant. The march never moves the cursor;
// a tap or a scroll cancels it.
//
// Leaving the page closes the probe: its transcripts go into the lab log.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/hardware_probe_runner.dart';
import '../../gestures/hardware_probes.dart';
import '../../gestures/pattern_transcript.dart';
import '../ui2.dart';

/// The metronome's four coloured steps A, C, D, E. The dot and the dashes both
/// read this, so they cannot drift apart: dash k uses colour k.
const List<Color> kPatternUnitColours = [C.blue, C.green, C.orange, C.purple];

/// Steps in one 4/4 bar.
const int _barSteps = 8;

class PatternProbePage extends StatefulWidget {
  const PatternProbePage({super.key, required this.runner});
  final HardwareProbeRunner runner;

  @override
  State<PatternProbePage> createState() => _PatternProbePageState();
}

class _PatternProbePageState extends State<PatternProbePage> {
  late final FixedExtentScrollController _wheel;
  // True while the wearer's finger (or its fling) moves the wheel. Only then
  // does the wheel move the cursor; a jump or a clamp when the list changes
  // length must not.
  bool _userScrolling = false;

  // The metronome: a step 0 to 7, ticking every unit.
  Timer? _tick;
  int _tickMs = 0;
  int _step = 0;

  // The march: set when Play starts on a rendition with entries, started when
  // the first write has landed, ended by the last timer, a tap or a scroll.
  final List<Timer> _march = [];
  bool _pendingMarch = false;
  bool _marching = false;
  int? _head;
  int _seenPlays = 0;
  // What a tap, a toggle, a rendition or test switch would change; a change in
  // it cancels the march.
  String _editSig = '';

  @override
  void initState() {
    super.initState();
    final r = widget.runner;
    _wheel = FixedExtentScrollController(initialItem: r.pattern?.cursor ?? 0);
    _seenPlays = r.patternPlays;
    _editSig = _sig(r.pattern);
    _startTick(reset: true);
    r.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runner.removeListener(_changed);
    _tick?.cancel();
    _stopMarch();
    _wheel.dispose();
    // The usual exit closes the probe in [_popped]. A page removed any other
    // way closes it here, a microtask later: closing writes to the lab log and
    // notifies its listeners, which is not allowed while the tree is torn down.
    scheduleMicrotask(widget.runner.closePattern);
    super.dispose();
  }

  /// Going back closes the probe at once, before the exit animation, and this
  /// page stops listening so it does not redraw as an empty screen on the way
  /// out.
  void _popped(bool didPop, Object? _) {
    if (!didPop) return;
    widget.runner.removeListener(_changed);
    _tick?.cancel();
    _stopMarch();
    widget.runner.closePattern();
  }

  static String _sig(PatternEntrySession? s) => s == null
      ? ''
      : '${s.testIndex}/${s.activeRendition}/${s.cursor}/${s.active.code}/'
            '${s.nextIsNote}';

  void _changed() {
    if (!mounted) return;
    final r = widget.runner;
    final s = r.pattern;
    if (s == null) {
      _tick?.cancel();
      _stopMarch();
    } else {
      if (r.patternPlays != _seenPlays) {
        // A play started: the dot goes back to step 1, and a rendition with
        // entries will march once the band's first write has landed.
        _seenPlays = r.patternPlays;
        _stopMarch();
        _pendingMarch = s.active.length > 0;
        _startTick(reset: true);
        _editSig = _sig(s);
      } else if (_sig(s) != _editSig) {
        _editSig = _sig(s);
        _stopMarch();
      }
      final written = r.patternPlayWrittenAt;
      if (_pendingMarch && written != null) {
        _startMarch(s, written);
      } else if (_pendingMarch && !r.patternPlaying) {
        _pendingMarch = false;
      }
      if (s.unitMs != _tickMs) _startTick();
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncWheel());
  }

  /// (Re)start the metronome at the session's tempo; [reset] goes back to step
  /// 1, otherwise the step carries on at the new pace.
  void _startTick({bool reset = false}) {
    _tick?.cancel();
    _tickMs = widget.runner.pattern?.unitMs ??
        PatternEntrySession.defaultUnitMs;
    if (reset) _step = 0;
    _tick = Timer.periodic(patternMs(_tickMs), (_) {
      if (mounted) setState(() => _step = (_step + 1) % _barSteps);
    });
  }

  /// Schedule the playhead: entry i at [written] + its start on the march
  /// plan, which already includes the lead. Delays are measured from now, so a
  /// late start catches up instead of drifting.
  void _startMarch(PatternEntrySession s, DateTime written) {
    _pendingMarch = false;
    final plan = PatternEntrySession.march(s.active, s.unitMs, s.leadMs);
    if (plan.isEmpty) return;
    _marching = true;
    final now = DateTime.now();
    Duration at(int ms) => patternMs(
      math.max(0, written.add(patternMs(ms)).difference(now).inMilliseconds),
    );
    _march.add(
      Timer(at(plan.first.startMs), () {
        if (mounted) setState(() => _startTick(reset: true));
      }),
    );
    for (final e in plan) {
      _march.add(Timer(at(e.startMs), () => _playhead(e.index)));
    }
    _march.add(Timer(at(plan.last.endMs), _marchEnded));
  }

  void _playhead(int i) {
    if (!mounted || !_marching) return;
    setState(() => _head = i);
    _glideTo(i);
  }

  void _marchEnded() {
    if (!mounted || !_marching) return;
    _marching = false;
    setState(() => _head = null);
    final s = widget.runner.pattern;
    if (s != null) _glideTo(s.cursor);
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

  /// Cancel any march, pending or running. The caller redraws.
  void _stopMarch() {
    for (final t in _march) {
      t.cancel();
    }
    _march.clear();
    _pendingMarch = false;
    _marching = false;
    _head = null;
  }

  /// Put the wheel on the cursor after an edit, a new test or a rendition
  /// switch moved the cursor by something other than scrolling. Not while a
  /// march is moving it.
  void _syncWheel() {
    final s = widget.runner.pattern;
    if (!mounted || s == null || !_wheel.hasClients || _marching) return;
    if (_wheel.selectedItem == s.cursor) return;
    _wheel.jumpToItem(s.cursor);
  }

  void _scrolled(int item) {
    final s = widget.runner.pattern;
    if (!_userScrolling || s == null || item == s.cursor) return;
    widget.runner.patternMove(item - s.cursor);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final r = widget.runner;
    final s = r.pattern;
    if (s == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return Scaffold(backgroundColor: p.bg, body: const SizedBox.shrink());
    }
    final test = s.tests[s.testIndex];
    final active = s.active;
    final noteNext = s.nextIsNote;
    return PopScope<Object?>(
      onPopInvokedWithResult: _popped,
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: S.x4),
                child: NavBar('Pattern probe'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
                child: _Header(
                  runner: r,
                  session: s,
                  test: test,
                  step: _step,
                ),
              ),
              const SizedBox(height: S.x2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
                child: Text(
                  'Pick Note or Rest, then a length. The toggle alternates after '
                  'each entry; tap it to change. Scroll to an entry to change it.',
                  style: F.cap.copyWith(color: p.ink2, height: 1.3),
                ),
              ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollStartNotification) {
                      _userScrolling = n.dragDetails != null;
                      if (_userScrolling && (_marching || _pendingMarch)) {
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
                    itemExtent: _rowExtent,
                    diameterRatio: 3,
                    physics: const FixedExtentScrollPhysics(),
                    onSelectedItemChanged: _scrolled,
                    children: [
                      for (var i = 0; i <= active.length; i++)
                        _EntryRow(
                          index: i,
                          note: i < active.length
                              ? active.entries[i].note
                              : noteNext,
                          length: i < active.length
                              ? active.entries[i].length
                              : null,
                          selected: i == s.cursor,
                          playing: i == _head,
                        ),
                    ],
                  ),
                ),
              ),
              Container(
                color: p.card,
                padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Each play waits for the band to finish the last one; at '
                      'most ${PatternProbe.maxCommands} commands per session; '
                      'leaving this screen stops it.',
                      style: F.cap.copyWith(color: p.ink2, height: 1.3),
                    ),
                    const SizedBox(height: S.x2),
                    Row(
                      children: [
                        for (var n = 1; n <= 4; n++) ...[
                          if (n > 1) const SizedBox(width: S.x2),
                          Expanded(
                            child: _LengthButton(
                              key: ValueKey('pattern-len-$n'),
                              length: n,
                              note: noteNext,
                              onTap: () => r.patternTap(n),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: S.x2),
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
                            onTap: r.patternToggleKind,
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
                            onTap: r.patternDelete,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const double _rowExtent = 52;

/// The test, Play with the metronome dot, the A / B switch, and the tempo.
class _Header extends StatelessWidget {
  const _Header({
    required this.runner,
    required this.session,
    required this.test,
    required this.step,
  });
  final HardwareProbeRunner runner;
  final PatternEntrySession session;
  final PatternTest test;
  final int step;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final i = session.testIndex;
    final last = session.tests.length - 1;
    final playing = runner.patternPlaying;
    final fitted = session.dynamicTempo && session.fittedUnitMs() != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _StepButton(
              key: const ValueKey('pattern-prev'),
              icon: LucideIcons.chevronLeft,
              label: 'Previous test',
              onTap: i > 0 ? () => runner.patternTest(-1) : null,
            ),
            Expanded(
              child: Text(
                'Test ${i + 1} of ${session.tests.length}',
                textAlign: TextAlign.center,
                style: F.head.copyWith(color: p.ink),
              ),
            ),
            _StepButton(
              key: const ValueKey('pattern-next'),
              icon: LucideIcons.chevronRight,
              label: 'Next test',
              onTap: i < last ? () => runner.patternTest(1) : null,
            ),
          ],
        ),
        Text(
          test.description,
          textAlign: TextAlign.center,
          style: F.cap.copyWith(color: p.ink2, height: 1.3),
        ),
        const SizedBox(height: S.x2),
        Row(
          children: [
            _MetronomeDot(step: step),
            const SizedBox(width: S.x3),
            Expanded(
              flex: 2,
              child: BigButton(
                playing ? 'Playing…' : 'Play',
                key: const ValueKey('pattern-play'),
                icon: LucideIcons.vibrate,
                color: C.blue,
                onTap: playing ? null : runner.playPattern,
              ),
            ),
            const SizedBox(width: S.x2),
            Expanded(
              child: BigButton(
                'A',
                key: const ValueKey('pattern-rendition-a'),
                soft: session.activeRendition != 0,
                color: C.blue,
                onTap: () => runner.patternRendition(0),
              ),
            ),
            const SizedBox(width: S.x2),
            Expanded(
              child: BigButton(
                'B',
                key: const ValueKey('pattern-rendition-b'),
                soft: session.activeRendition != 1,
                color: C.blue,
                onTap: () => runner.patternRendition(1),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '1 = ${session.unitMs} ms${fitted ? ' · fitted' : ''}',
                style: F.cap.copyWith(color: p.ink2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('Dynamic tempo', style: F.cap.copyWith(color: p.ink2)),
            const SizedBox(width: S.x2),
            Semantics(
              label: 'Dynamic tempo',
              excludeSemantics: true,
              child: Switch(
                key: const ValueKey('pattern-dynamic-tempo'),
                value: session.dynamicTempo,
                onChanged: runner.patternDynamicTempo,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        Text(
          'Played ${session.plays(i)}×',
          textAlign: TextAlign.center,
          style: F.cap.copyWith(color: p.ink2),
        ),
      ],
    );
  }
}

/// The metronome: one dot, a solid colour on steps 1, 3, 5, 7 (A, C, D, E) and
/// an outline between. It does not animate between steps.
class _MetronomeDot extends StatelessWidget {
  const _MetronomeDot({required this.step});
  final int step;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      key: const ValueKey('pattern-metronome'),
      container: true,
      label: 'metronome step ${step + 1} of $_barSteps',
      child: SizedBox(
        width: 14,
        height: 14,
        child: DecoratedBox(
          decoration: step.isEven
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  color: kPatternUnitColours[step ~/ 2],
                )
              : BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: p.ink3, width: 1.5),
                ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: SizedBox(
        width: S.tap,
        height: S.tap,
        child: Icon(icon, size: 24, color: onTap == null ? p.ink3 : p.ink),
      ),
    );
  }
}

const _lengthNames = ['eighth', 'quarter', 'dotted quarter', 'half'];

/// Dash [k] (1-based) of a length: the metronome's colour k, at a third of the
/// saturation for a rest.
Color _dashColour(int k, bool note) {
  final c = kPatternUnitColours[k - 1];
  if (note) return c;
  final hsl = HSLColor.fromColor(c);
  return hsl.withSaturation(hsl.saturation / 3).toColor();
}

/// A length as music: the note or rest symbol above one coloured dash per
/// unit.
class _Notation extends StatelessWidget {
  const _Notation({required this.length, required this.note});
  final int length;
  final bool note;

  @override
  Widget build(BuildContext c) {
    final ink = P.of(c).ink;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${_lengthNames[length - 1]} ${note ? 'note' : 'rest'}',
          child: CustomPaint(
            key: const ValueKey('pattern-symbol'),
            size: const Size(24, 28),
            painter: _SymbolPainter(length: length, note: note, color: ink),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var k = 1; k <= length; k++) ...[
              if (k > 1) const SizedBox(width: S.x1),
              SizedBox(
                width: S.x4,
                height: S.x1,
                child: DecoratedBox(
                  key: ValueKey('dash-$k'),
                  decoration: BoxDecoration(
                    color: _dashColour(k, note),
                    borderRadius: R.rPill,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Draws an eighth, quarter, dotted quarter or half note, or the matching
/// rest, in a 24 x 28 box. Painted, not a font glyph: Android fonts may not
/// have the music block.
class _SymbolPainter extends CustomPainter {
  const _SymbolPainter({
    required this.length,
    required this.note,
    required this.color,
  });
  final int length;
  final bool note;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (note) {
      _paintNote(canvas, fill, line);
    } else {
      _paintRest(canvas, fill, line);
    }
  }

  void _paintNote(Canvas canvas, Paint fill, Paint line) {
    const cx = 7.0, cy = 22.0;
    final head = Rect.fromCenter(center: Offset.zero, width: 10, height: 7.4);
    canvas
      ..save()
      ..translate(cx, cy)
      ..rotate(-0.35);
    // A half note's head is hollow; the others are filled.
    canvas.drawOval(head, length == 4 ? line : fill);
    canvas.restore();
    const stemX = cx + 4.4;
    canvas.drawLine(const Offset(stemX, cy - 1), const Offset(stemX, 2), line);
    if (length == 1) {
      canvas.drawPath(
        Path()
          ..moveTo(stemX, 2.5)
          ..cubicTo(stemX + 2, 9, stemX + 9, 10, stemX + 5, 18),
        line,
      );
    }
    if (length == 3) canvas.drawCircle(const Offset(cx + 11, cy - 1), 1.7, fill);
  }

  void _paintRest(Canvas canvas, Paint fill, Paint line) {
    switch (length) {
      case 1:
        // An eighth rest: a dot with a flag on a slanted stem.
        canvas.drawCircle(const Offset(8, 9), 2.3, fill);
        canvas.drawPath(
          Path()
            ..moveTo(8, 9)
            ..quadraticBezierTo(12, 11, 15, 5)
            ..lineTo(9, 25),
          line,
        );
      case 4:
        // A half rest: a block sitting on the line.
        canvas.drawLine(const Offset(3, 15), const Offset(21, 15), line);
        canvas.drawRect(const Rect.fromLTRB(7, 9.5, 17, 14.5), fill);
      default:
        // A quarter rest (dotted for 3): the zigzag.
        canvas.drawPath(
          Path()
            ..moveTo(8, 3)
            ..lineTo(14, 10)
            ..lineTo(9, 15.5)
            ..lineTo(14, 21)
            ..cubicTo(8, 20, 7, 27, 12.5, 26),
          line,
        );
        if (length == 3) canvas.drawCircle(const Offset(19, 11), 1.7, fill);
    }
  }

  @override
  bool shouldRepaint(_SymbolPainter o) =>
      o.length != length || o.note != note || o.color != color;
}

/// One footer button: writes [length] as the kind of entry it shows.
class _LengthButton extends StatelessWidget {
  const _LengthButton({
    super.key,
    required this.length,
    required this.note,
    required this.onTap,
  });
  final int length;
  final bool note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final label = '${note ? 'Note' : 'Rest'} $length';
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        decoration: BoxDecoration(
          color: p.wash(note ? C.blue : C.n400),
          borderRadius: R.rMd,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Notation(length: length, note: note),
            const SizedBox(height: S.x1),
            Text(
              label,
              style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600),
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// One wheel row: kind, index, the notation. [length] null is the empty next
/// slot. [playing] marks the entry the march is on.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.index,
    required this.note,
    required this.length,
    required this.selected,
    required this.playing,
  });
  final int index;
  final bool note;
  final int? length;
  final bool selected;
  final bool playing;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final kind = note ? 'Note' : 'Rest';
    final label = length == null ? 'Next entry ($kind)' : kind;
    final said = length == null ? label : '$label $length, entry ${index + 1}';
    return Semantics(
      selected: selected,
      label: playing ? 'playing entry ${index + 1}, $said' : said,
      excludeSemantics: true,
      child: Container(
        key: playing ? const ValueKey('pattern-playhead') : null,
        margin: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x1),
        padding: const EdgeInsets.symmetric(horizontal: S.x4),
        decoration: BoxDecoration(
          color: playing || selected
              ? p.wash(note ? C.blue : C.n400)
              : p.card,
          borderRadius: R.rMd,
          border: playing
              ? Border.all(color: C.blue, width: 2)
              : selected
              ? Border.all(color: p.ink3)
              : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: S.x8,
              child: Text('${index + 1}', style: F.cap.copyWith(color: p.ink3)),
            ),
            Expanded(
              child: Text(
                label,
                style: F.body.copyWith(
                  color: length == null ? p.ink2 : p.ink,
                  fontWeight: selected || playing
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (length != null) _Notation(length: length!, note: note),
          ],
        ),
      ),
    );
  }
}
