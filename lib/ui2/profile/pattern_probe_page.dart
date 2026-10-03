// Pattern probe page (8Y/8Z/8AA/8AB) — the transcriber the wearer taps.
//
// The band plays one test on demand. The wearer writes down what they felt in
// music terms: notes and rests. One unit is a sixteenth, so a length of 1, 2,
// 3, 4, 6, 8, 12 is a 16th, eighth, dotted eighth, quarter, dotted quarter,
// half, dotted half, drawn as the matching note or rest symbol above one
// coloured dash per sixteenth (the colour is the beat the sixteenth falls in).
// The four length buttons are 16th, eighth, quarter and half; a Dot toggle next
// to them makes the next tap 3/2 as long (one shot; a 16th cannot be dotted).
// Every note also has a dynamic, ff, mf, mp or pp, picked on a row above the
// length buttons and sticky until changed; with the cursor on a note, picking
// one changes that note. A Note/Rest toggle flips after every tap and can be
// overridden, so two notes or two rests can sit next to each other. The entries
// sit on a wheel; the centred one is the cursor, so scrolling goes back and
// forward through them and a length button replaces the entry in the middle. Up
// to two renditions (A and B) per test, because the band may not play a pattern
// the same way twice. The footer stays on screen whatever the list does.
//
// The metronome dot is off until Play. Play starts a one-measure count-in
// (4/4: sixteen steps to a bar, the beat's colour on each quarter, the same
// colour faint on each "and", dark between) and asks the band so that it starts
// on the next downbeat, one measured Bluetooth lead early. A rendition with
// entries marches a playhead through them from that downbeat. The metronome
// runs on until the play has finished and the march has ended, plus one padding
// measure to the bar line, then goes idle. A refused play stops it at once and
// says why under Play. The march never moves the cursor; a tap or a scroll
// cancels it.
//
// A small display shows how many of the band's 30 commands in 2 minutes are
// left and when the next one frees up. It is blurred until tapped, so its
// countdown does not pull the eye off the metronome.
//
// Finish (or going back) closes the probe, its transcripts go into the lab log,
// and an end screen shows the totals with a button that copies the whole lab
// log. Done (or going back again) leaves.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/hardware_probe_runner.dart';
import '../../gestures/hardware_probes.dart';
import '../../gestures/pattern_transcript.dart';
import '../ui2.dart';
import '../../haptics/tap_notes.dart';
import 'pattern_notation.dart';
import 'tap_take_pad.dart';

/// Steps in one 4/4 bar.
const int _barSteps = 16;

/// The lengths with a button of their own; the Dot makes 2, 4, 8 into 3, 6, 12.
const List<int> _buttonLengths = [1, 2, 4, 8];

class PatternProbePage extends StatefulWidget {
  const PatternProbePage({
    super.key,
    required this.runner,
    required this.logText,
  });
  final HardwareProbeRunner runner;

  /// The text of the Device lab's "Copy all logs", read when the end screen's
  /// copy button is tapped (after the session closed, so the heard lines are
  /// in it).
  final String Function() logText;

  @override
  State<PatternProbePage> createState() => _PatternProbePageState();
}

/// What the end screen shows, taken before the session closes.
class _EndSummary {
  _EndSummary(PatternEntrySession s)
    : transcribed = s.testsTranscribed,
      tests = s.tests.length,
      plays = s.totalPlays,
      unitMs = s.unitMs,
      fitted = s.dynamicTempo && s.fittedUnitMs() != null,
      leadMs = s.leadMs,
      leadMeasured = s.leadMeasured;
  final int transcribed, tests, plays, unitMs, leadMs;
  final bool fitted, leadMeasured;
}

class _PatternProbePageState extends State<PatternProbePage> {
  late final FixedExtentScrollController _wheel;
  // True while the wearer's finger (or its fling) moves the wheel. Only then
  // does the wheel move the cursor; a jump or a clamp when the list changes
  // length must not.
  bool _userScrolling = false;

  // The metronome: off until Play, then a step 0 to 15 every unit.
  Timer? _tick;
  bool _metroOn = false;
  int _step = 0;
  // The unit of the run in progress and when Play was pressed: the count-in,
  // the march and the padding measure all sit on this one grid of bars.
  int _runUnitMs = PatternEntrySession.defaultUnitMs;
  DateTime _pressedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // A play, from the press: [_counting] until the band is asked, [_awaitPlay]
  // until it has finished, [_awaitMarch] until the march's last entry ends.
  // When none is left the metronome stops at a bar line, a measure on.
  Timer? _ask;
  Timer? _stopTimer;
  bool _counting = false;
  bool _awaitPlay = false;
  bool _awaitMarch = false;

  // The march: timers from the press, ended by the last one, a tap or a scroll.
  final List<Timer> _march = [];
  bool _marching = false;
  int? _head;
  // What a tap, a toggle, a rendition or test switch would change; a change in
  // it cancels the march.
  String _editSig = '';

  // A redraw each second: the countdowns (rest line, limit display).
  Timer? _second;
  bool _limitBlurred = true;

  // The end screen.
  bool _ended = false;
  _EndSummary? _summary;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    final r = widget.runner;
    _wheel = FixedExtentScrollController(initialItem: r.pattern?.cursor ?? 0);
    _editSig = _sig(r.pattern);
    _second = Timer.periodic(patternMs(1000), (_) {
      if (mounted) setState(() {});
    });
    r.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runner.removeListener(_changed);
    _stopAll();
    _second?.cancel();
    _wheel.dispose();
    // The usual exit closes the probe in [_finish] or [_popped]. A page removed
    // any other way closes it here, a microtask later: closing writes to the
    // lab log and notifies its listeners, which is not allowed while the tree
    // is torn down.
    scheduleMicrotask(widget.runner.closePattern);
    super.dispose();
  }

  /// Going back from the transcriber is a Finish: the page stays, as the end
  /// screen. A pop that did happen (the end screen's Done or back, or the route
  /// removed) closes the probe at once, before the exit animation, and this
  /// page stops listening so it does not redraw as an empty screen on the way
  /// out.
  void _popped(bool didPop, Object? _) {
    if (!didPop) {
      _finish();
      return;
    }
    widget.runner.removeListener(_changed);
    _stopAll();
    _second?.cancel();
    widget.runner.closePattern();
  }

  /// Close the session, then show the end screen.
  void _finish() {
    if (_ended) return;
    final r = widget.runner;
    final s = r.pattern;
    _stopAll();
    _second?.cancel();
    r.removeListener(_changed);
    setState(() {
      _ended = true;
      if (s != null) _summary = _EndSummary(s);
    });
    r.closePattern();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.logText()));
    if (mounted) setState(() => _copied = true);
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
      _stopAll();
    } else {
      if (_sig(s) != _editSig) {
        _editSig = _sig(s);
        _stopMarch();
        _checkDone();
      }
      if (_awaitPlay && !_counting && !r.patternPlaying) {
        _awaitPlay = false;
        _checkDone();
      }
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncWheel());
  }

  /// Play: a one-measure count-in on the metronome, the band asked so that it
  /// starts on the downbeat, a rendition with entries marched from there.
  void _play() {
    final r = widget.runner;
    final s = r.pattern;
    if (s == null || _counting || r.patternPlaying) return;
    _stopAll();
    final bar = (_runUnitMs = s.unitMs) * _barSteps;
    _pressedAt = clock.now();
    _counting = true;
    _startTick();
    _ask = Timer(patternMs(math.max(0, bar - s.leadMs)), _askBand);
    if (s.active.length > 0) _startMarch(s, bar);
    setState(() {});
  }

  /// The count-in's end less the lead: ask the band. The probe decides a
  /// refusal at once, so it shows here; a refused play stops everything.
  void _askBand() {
    _ask = null;
    if (!mounted) return;
    final r = widget.runner;
    _counting = false;
    _awaitPlay = true;
    unawaited(r.playPattern());
    if (r.patternRefusal != null || !r.patternPlaying) _stopAll();
    setState(() {});
  }

  void _startTick() {
    _tick?.cancel();
    _step = 0;
    _metroOn = true;
    _tick = Timer.periodic(patternMs(_runUnitMs), (_) {
      if (mounted) setState(() => _step = (_step + 1) % _barSteps);
    });
  }

  /// Everything off: metronome, count-in, march, the pending stop.
  void _stopAll() {
    _tick?.cancel();
    _tick = null;
    _ask?.cancel();
    _ask = null;
    _stopTimer?.cancel();
    _stopTimer = null;
    _metroOn = false;
    _counting = false;
    _awaitPlay = false;
    _stopMarch();
  }

  /// Once the play has finished and the march has ended (or was cancelled),
  /// stop the metronome at the first bar line a full measure on.
  void _checkDone() {
    if (!_metroOn || _counting || _awaitPlay || _awaitMarch) return;
    if (_stopTimer != null) return;
    final bar = _runUnitMs * _barSteps;
    final now = clock.now().difference(_pressedAt).inMilliseconds;
    final at = (now + 2 * bar - 1) ~/ bar * bar;
    _stopTimer = Timer(patternMs(at - now), () {
      _stopTimer = null;
      if (!mounted) return;
      setState(() {
        _tick?.cancel();
        _tick = null;
        _metroOn = false;
      });
    });
  }

  /// Schedule the playhead: entry i at the downbeat, [bar] ms after the press,
  /// plus its start on the march plan. All offsets are from the press, so a
  /// late timer does not push the next one back.
  void _startMarch(PatternEntrySession s, int bar) {
    final plan = PatternEntrySession.march(s.active, _runUnitMs, 0);
    if (plan.isEmpty) return;
    _marching = true;
    _awaitMarch = true;
    for (final e in plan) {
      _march.add(Timer(patternMs(bar + e.startMs), () => _playhead(e.index)));
    }
    _march.add(Timer(patternMs(bar + plan.last.endMs), _marchEnded));
  }

  void _playhead(int i) {
    if (!mounted || !_marching) return;
    setState(() => _head = i);
    _glideTo(i);
  }

  void _marchEnded() {
    if (!mounted || !_marching) return;
    _marching = false;
    _awaitMarch = false;
    setState(() => _head = null);
    final s = widget.runner.pattern;
    if (s != null) _glideTo(s.cursor);
    _checkDone();
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
    _marching = false;
    _awaitMarch = false;
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

  /// "Tap what you felt": a tap pad whose take, as mf notes, fills the active
  /// rendition after asking when it already has entries.
  Future<void> _tapBaseline() async {
    final s = widget.runner.pattern;
    if (s == null) return;
    final take = await takeTapsForPattern(
      context,
      hasNotes: s.active.length > 0,
      padKey: const ValueKey('pattern-tap-pad'),
    );
    if (take == null || !mounted) return;
    widget.runner.patternSetRendition(notesFromTaps(take, unitMs: s.unitMs));
  }

  /// The line under Play for a refused play; null when there is none. A new
  /// press hides it until the band has been asked again.
  String? _refusalText() {
    if (_counting) return null;
    final r = widget.runner;
    switch (r.patternRefusal) {
      case null:
        return null;
      case PatternRefusal.resting:
        final left = r.patternRestRemaining;
        return left == null
            ? 'Band rested, ready to play'
            : 'Band resting, ready in ${math.max(1, left.inSeconds)} s';
      case PatternRefusal.notConnected:
        return 'Not connected';
      case PatternRefusal.busy:
        return 'Still playing';
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final r = widget.runner;
    final s = r.pattern;
    if (_ended) return _buildEnd(c, p);
    if (s == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return PopScope<Object?>(
        onPopInvokedWithResult: _popped,
        child: Scaffold(backgroundColor: p.bg, body: const SizedBox.shrink()),
      );
    }
    final test = s.tests[s.testIndex];
    final active = s.active;
    final noteNext = s.nextIsNote;
    final dot = s.dotNext;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: _popped,
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
                child: NavBar(
                  'Pattern probe',
                  trailingWidth: 72 + S.tap + S.x1,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 8AD: fill the active rendition from taps. It sits
                      // here because the footer has no width or height to
                      // spare at 360 x 640.
                      _TapBaselineButton(
                        key: const ValueKey('pattern-tap-baseline'),
                        onTap: _tapBaseline,
                      ),
                      const SizedBox(width: S.x1),
                      Flexible(
                        child: Pressable(
                          key: const ValueKey('pattern-finish'),
                          onTap: _finish,
                          semanticLabel: 'Finish',
                          child: Text(
                            'Finish',
                            style: F.body.copyWith(
                              color: p.on(C.blue),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
                child: _Header(
                  runner: r,
                  session: s,
                  test: test,
                  step: _metroOn ? _step : null,
                  counting: _counting,
                  onPlay: _play,
                  refusal: _refusalText(),
                ),
              ),
              const SizedBox(height: S.x1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
                child: Text(
                  'Pick Note or Rest, then a length. The toggle alternates after '
                  'each entry; tap it to change. Scroll to an entry to change it.',
                  style: F.cap.copyWith(color: p.ink2, height: 1.3),
                ),
              ),
              Expanded(
                // The limit display floats over the wheel's bottom corner, the
                // empty half while the list grows: it costs the screen no
                // height and sits as far from the metronome as the page
                // allows.
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n is ScrollStartNotification) {
                            _userScrolling = n.dragDetails != null;
                            if (_userScrolling && _marching) {
                              setState(() {
                                _stopMarch();
                                _checkDone();
                              });
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
                                length: i < active.length
                                    ? active.entries[i].length
                                    : null,
                                dynamic: i < active.length
                                    ? active.entries[i].dynamic
                                    : null,
                                selected: i == s.cursor,
                                playing: i == _head,
                              ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: S.x1,
                      right: S.x4,
                      child: _LimitDisplay(
                        key: const ValueKey('pattern-limit'),
                        left: r.patternCommandsLeft,
                        nextIn: r.patternNextFreeIn,
                        blurred: _limitBlurred,
                        onTap: () =>
                            setState(() => _limitBlurred = !_limitBlurred),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                color: p.card,
                padding: const EdgeInsets.fromLTRB(S.x4, S.x1, S.x4, S.x1),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Each play waits for the band to finish the last one; at '
                      'most ${PatternProbe.maxCommandsPerWindow} commands in '
                      'any 2 minutes; leaving this screen stops it.',
                      style: F.cap.copyWith(color: p.ink2, height: 1.3),
                    ),
                    const SizedBox(height: S.x1),
                    Row(
                      children: [
                        for (final d in PatternDynamic.values) ...[
                          if (d != PatternDynamic.values.first)
                            const SizedBox(width: S.x2),
                          Expanded(
                            child: PatternDynamicButton(
                              key: ValueKey('pattern-dyn-${d.name}'),
                              dynamic: d,
                              selected: d == s.nextDynamic,
                              dim: !noteNext,
                              onTap: () => r.patternDynamic(d),
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
                                    : () => r.patternTap(n),
                              ),
                            ),
                            const SizedBox(width: S.x1),
                          ],
                          Expanded(
                            child: PatternDotButton(
                              key: const ValueKey('pattern-dot'),
                              selected: dot,
                              onTap: r.patternToggleDot,
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

  /// The end screen: the session is already closed.
  Widget _buildEnd(BuildContext c, P p) {
    final e = _summary;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: F.body.copyWith(color: p.ink2)),
          const SizedBox(width: S.x3),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: F.body.copyWith(
                color: p.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return PopScope<Object?>(
      // Back from here is Done.
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
              Expanded(
                child: ListView(
                  key: const ValueKey('pattern-end'),
                  padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
                  children: [
                    Text(
                      'Session finished',
                      style: F.head.copyWith(color: p.ink),
                    ),
                    const SizedBox(height: S.x1),
                    Text(
                      'What you wrote is in the lab log. Copy the whole log to '
                      'send it.',
                      style: F.cap.copyWith(color: p.ink2, height: 1.3),
                    ),
                    const SizedBox(height: S.x3),
                    if (e != null)
                      Surface(
                        child: Column(
                          children: [
                            row(
                              'Tests transcribed',
                              '${e.transcribed} of ${e.tests}',
                            ),
                            row('Plays', '${e.plays}'),
                            row(
                              'Tempo',
                              '1 sixteenth ≈ ${e.unitMs} ms '
                                  '(${e.fitted ? 'fitted' : 'fixed'})',
                            ),
                            row(
                              'Bluetooth lead',
                              '${e.leadMs} ms'
                              '${e.leadMeasured ? '' : ' (default)'}',
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_copied)
                      Padding(
                        padding: const EdgeInsets.only(bottom: S.x2),
                        child: Semantics(
                          liveRegion: true,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(LucideIcons.check, size: 16, color: p.ink2),
                              const SizedBox(width: S.x1),
                              Text(
                                'Copied',
                                style: F.cap.copyWith(color: p.ink2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    BigButton(
                      'Copy all logs',
                      key: const ValueKey('pattern-copy'),
                      icon: LucideIcons.copy,
                      soft: true,
                      color: C.blue,
                      onTap: _copy,
                    ),
                    const SizedBox(height: S.x2),
                    BigButton(
                      'Done',
                      key: const ValueKey('pattern-done'),
                      color: C.blue,
                      onTap: () => Navigator.of(c).pop(),
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

/// Whole seconds in [d], rounded up, never below 0.
int _wholeSeconds(Duration d) => math.max(0, (d.inMilliseconds / 1000).ceil());

/// The test, Play with the metronome dot, the A / B switch, and the tempo.
class _Header extends StatelessWidget {
  const _Header({
    required this.runner,
    required this.session,
    required this.test,
    required this.step,
    required this.counting,
    required this.onPlay,
    required this.refusal,
  });
  final HardwareProbeRunner runner;
  final PatternEntrySession session;
  final PatternTest test;

  /// The metronome step 0 to 15; null while it is off.
  final int? step;

  /// The count-in before the band is asked is running.
  final bool counting;
  final VoidCallback onPlay;

  /// Why the latest play was refused; null for no line.
  final String? refusal;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final i = session.testIndex;
    final last = session.tests.length - 1;
    final playing = runner.patternPlaying;
    final unstable = session.unstable(i);
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
            // The band's timing for this test varies: A and B are then its
            // shortest and longest renditions.
            _UnstableToggle(
              key: const ValueKey('pattern-unstable'),
              selected: unstable,
              onTap: runner.patternToggleUnstable,
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
        const SizedBox(height: S.x1),
        Row(
          children: [
            _MetronomeDot(step: step),
            const SizedBox(width: S.x3),
            Expanded(
              flex: 2,
              child: BigButton(
                playing
                    ? 'Playing…'
                    : counting
                    ? 'Count-in…'
                    : 'Play',
                key: const ValueKey('pattern-play'),
                icon: LucideIcons.vibrate,
                color: C.blue,
                onTap: playing || counting ? null : onPlay,
              ),
            ),
            const SizedBox(width: S.x2),
            Expanded(
              child: _RenditionChip(
                unstable ? 'A · shortest' : 'A',
                key: const ValueKey('pattern-rendition-a'),
                soft: session.activeRendition != 0,
                onTap: () => runner.patternRendition(0),
              ),
            ),
            const SizedBox(width: S.x2),
            Expanded(
              child: _RenditionChip(
                unstable ? 'B · longest' : 'B',
                key: const ValueKey('pattern-rendition-b'),
                soft: session.activeRendition != 1,
                onTap: () => runner.patternRendition(1),
              ),
            ),
          ],
        ),
        if (refusal != null)
          Padding(
            key: const ValueKey('pattern-refused'),
            padding: const EdgeInsets.only(top: S.x1),
            child: Semantics(
              liveRegion: true,
              child: Text(
                refusal!,
                textAlign: TextAlign.center,
                style: F.cap.copyWith(
                  color: p.on(C.red),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: Text(
                '1 sixteenth = ${session.unitMs} ms${fitted ? ' · fitted' : ''}',
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

/// The metronome: one dot. Steps 1, 5, 9, 13 are the beat colours (A, C, D, E)
/// at full strength, steps 3, 7, 11, 15 the same colour at a third of the
/// saturation, and the even steps an outline. It does not animate. [step] null
/// is off: an outline, "metronome idle".
class _MetronomeDot extends StatelessWidget {
  const _MetronomeDot({required this.step});
  final int? step;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      key: const ValueKey('pattern-metronome'),
      container: true,
      label: step == null
          ? 'metronome idle'
          : 'metronome step ${step! + 1} of $_barSteps',
      child: SizedBox(
        width: 14,
        height: 14,
        child: DecoratedBox(
          decoration: step != null && step!.isEven
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  color: patternBeatColour(step! ~/ 4, note: step! % 4 == 0),
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

/// The Unstable toggle: selected while the open test is flagged.
class _UnstableToggle extends StatelessWidget {
  const _UnstableToggle({
    super.key,
    required this.selected,
    required this.onTap,
  });
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: 'Unstable',
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: S.x3,
            vertical: S.x2,
          ),
          decoration: BoxDecoration(
            color: selected ? p.wash(C.blue) : p.card,
            borderRadius: R.rMd,
            border: Border.all(
              color: selected ? C.blue : p.ink3,
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            'Unstable',
            style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}

/// A rendition chip like a soft or filled [BigButton], with tight side
/// padding so the longer unstable labels ("A · shortest") fit one third of a
/// 360 px row and wrap to two lines instead of overflowing.
class _RenditionChip extends StatelessWidget {
  const _RenditionChip(
    this.label, {
    super.key,
    required this.soft,
    required this.onTap,
  });
  final String label;
  final bool soft;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: S.x1),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: soft ? p.wash(C.blue) : p.fill(C.blue),
          borderRadius: R.rMd,
          boxShadow: soft ? null : p.el(2),
        ),
        child: Text(
          label,
          style: F.head.copyWith(color: soft ? p.on(C.blue) : p.inkOnFill),
          textAlign: TextAlign.center,
          maxLines: 2,
        ),
      ),
    );
  }
}

/// An icon button in the bar: fill the active rendition from taps.
class _TapBaselineButton extends StatelessWidget {
  const _TapBaselineButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: 'Tap what you felt',
      child: SizedBox(
        width: S.tap,
        height: S.tap,
        child: Icon(LucideIcons.hand, size: 22, color: p.on(C.blue)),
      ),
    );
  }
}

/// How many of the band's commands are left in the rolling window, and when the
/// next one frees up. Blurred until tapped: it is there to look at between
/// plays, not to pull the eye off the metronome. Under 5 left the count is red.
/// It scales down to fit whatever width the footer row gives it.
class _LimitDisplay extends StatelessWidget {
  const _LimitDisplay({
    super.key,
    required this.left,
    required this.nextIn,
    required this.blurred,
    required this.onTap,
  });
  final int left;
  final Duration? nextIn;
  final bool blurred;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final secs = nextIn == null ? null : _wholeSeconds(nextIn!);
    Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$left of ${PatternProbe.maxCommandsPerWindow} left',
          maxLines: 1,
          style: F.cap.copyWith(
            color: left < 5 ? C.red : p.ink2,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (secs != null)
          Text(
            'next in ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
            maxLines: 1,
            style: F.cap.copyWith(color: p.ink2),
          ),
      ],
    );
    if (blurred) {
      body = ExcludeSemantics(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: body,
        ),
      );
    }
    return Pressable(
      onTap: onTap,
      semanticLabel: blurred ? 'limit display, blurred' : 'limit display',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: R.rMd,
          border: Border.all(color: p.ink3.withValues(alpha: .5)),
        ),
        child: FittedBox(fit: BoxFit.scaleDown, child: body),
      ),
    );
  }
}
