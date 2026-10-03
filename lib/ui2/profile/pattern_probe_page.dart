// Pattern probe page (8Y) — the transcriber the wearer taps.
//
// The band plays one test on demand. The wearer writes down what they felt like
// morse: buttons of length 1 to 4, buzz and gap entries alternating (the first
// is a buzz). The entries sit on a wheel; the centred one is the cursor, so
// scrolling goes back and forward through them and a length button replaces the
// entry in the middle. Up to two renditions (A and B) per test, because the
// band may not play a pattern the same way twice. The footer of length buttons
// stays on screen whatever the list does.
//
// Leaving the page closes the probe: its transcripts go into the lab log.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/hardware_probe_runner.dart';
import '../../gestures/hardware_probes.dart';
import '../../gestures/pattern_transcript.dart';
import '../ui2.dart';

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

  @override
  void initState() {
    super.initState();
    _wheel = FixedExtentScrollController(
      initialItem: widget.runner.pattern?.cursor ?? 0,
    );
    widget.runner.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runner.removeListener(_changed);
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
    widget.runner.closePattern();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncWheel());
  }

  /// Put the wheel on the cursor after an edit, a new test or a rendition
  /// switch moved the cursor by something other than scrolling.
  void _syncWheel() {
    final s = widget.runner.pattern;
    if (!mounted || s == null || !_wheel.hasClients) return;
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
    final buzzNext = active.isBuzz(s.cursor);
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
                child: _Header(runner: r, session: s, test: test),
              ),
              const SizedBox(height: S.x2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
                child: Text(
                  'Buzzes and gaps alternate; the first entry is a buzz. Scroll to '
                  'an entry to change it.',
                  style: F.cap.copyWith(color: p.ink2, height: 1.3),
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
                    itemExtent: _rowExtent,
                    diameterRatio: 3,
                    physics: const FixedExtentScrollPhysics(),
                    onSelectedItemChanged: _scrolled,
                    children: [
                      for (var i = 0; i <= active.length; i++)
                        _EntryRow(
                          index: i,
                          buzz: active.isBuzz(i),
                          length: i < active.length ? active.lengths[i] : null,
                          selected: i == s.cursor,
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
                              buzz: buzzNext,
                              onTap: () => r.patternTap(n),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: S.x2),
                    BigButton(
                      'Delete',
                      key: const ValueKey('pattern-delete'),
                      icon: LucideIcons.delete,
                      soft: true,
                      color: C.red,
                      onTap: r.patternDelete,
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

/// The test, Play, and the A / B switch.
class _Header extends StatelessWidget {
  const _Header({
    required this.runner,
    required this.session,
    required this.test,
  });
  final HardwareProbeRunner runner;
  final PatternEntrySession session;
  final PatternTest test;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final i = session.testIndex;
    final last = session.tests.length - 1;
    final playing = runner.patternPlaying;
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
        const SizedBox(height: S.x1),
        Text(
          'Played ${session.plays(i)}×',
          textAlign: TextAlign.center,
          style: F.cap.copyWith(color: p.ink2),
        ),
      ],
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

/// A length as marks: [length] segments, solid for a buzz, hollow for a gap.
class _LengthMarks extends StatelessWidget {
  const _LengthMarks({required this.length, required this.buzz});
  final int length;
  final bool buzz;

  @override
  Widget build(BuildContext c) {
    final ink = P.of(c).ink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < length; i++) ...[
          if (i > 0) const SizedBox(width: S.x1),
          Container(
            width: S.x4,
            height: S.x2,
            decoration: BoxDecoration(
              color: buzz ? ink : null,
              border: buzz ? null : Border.all(color: ink, width: 1.5),
              borderRadius: R.rPill,
            ),
          ),
        ],
      ],
    );
  }
}

/// One footer button: writes [length] as the kind of entry it shows.
class _LengthButton extends StatelessWidget {
  const _LengthButton({
    super.key,
    required this.length,
    required this.buzz,
    required this.onTap,
  });
  final int length;
  final bool buzz;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final label = '${buzz ? 'Buzz' : 'Gap'} $length';
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        decoration: BoxDecoration(
          color: p.wash(buzz ? C.blue : C.n400),
          borderRadius: R.rMd,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LengthMarks(length: length, buzz: buzz),
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

/// One wheel row: kind, length marks, index. [length] null is the empty next
/// slot.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.index,
    required this.buzz,
    required this.length,
    required this.selected,
  });
  final int index;
  final bool buzz;
  final int? length;
  final bool selected;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final kind = buzz ? 'Buzz' : 'Gap';
    final label = length == null ? 'Next entry ($kind)' : kind;
    return Semantics(
      selected: selected,
      label: length == null ? label : '$label $length, entry ${index + 1}',
      excludeSemantics: true,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x1),
        padding: const EdgeInsets.symmetric(horizontal: S.x4),
        decoration: BoxDecoration(
          color: selected ? p.wash(buzz ? C.blue : C.n400) : p.card,
          borderRadius: R.rMd,
          border: selected ? Border.all(color: p.ink3) : null,
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
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (length != null) _LengthMarks(length: length!, buzz: buzz),
          ],
        ),
      ),
    );
  }
}
