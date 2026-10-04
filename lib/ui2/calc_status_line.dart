// "Sleep stages · 0:12" — the one line that says what is being calculated and
// for how long (P4b). Nothing when nothing is open: no spinner, no percentage,
// no estimate. It ticks once a second only while a step is open and the line is
// visible (TickerMode, so a hidden tab does no work), and the elapsed time is
// read from the clock each time rather than counted, so it catches up on its
// own after a pause.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../compute/calc_status.dart';
import 'theme.dart';

class CalcStatusLine extends StatefulWidget {
  const CalcStatusLine(
      {super.key, this.status, this.now, this.padding = EdgeInsets.zero});

  /// Defaults to the process-wide [CalcStatus.instance].
  final ValueListenable<CalcStep?>? status;

  /// The wall clock; tests hand in their own.
  final DateTime Function()? now;

  /// Space around the line while a step is open; nothing is reserved when idle,
  /// so a screen's layout does not move for a line that is not there.
  final EdgeInsets padding;

  @override
  State<CalcStatusLine> createState() => _CalcStatusLineState();
}

class _CalcStatusLineState extends State<CalcStatusLine> {
  Timer? _tick;
  bool _visible = true;

  ValueListenable<CalcStep?> get _status =>
      widget.status ?? CalcStatus.instance;

  @override
  void initState() {
    super.initState();
    _status.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(CalcStatusLine old) {
    super.didUpdateWidget(old);
    final was = old.status ?? CalcStatus.instance;
    if (!identical(was, _status)) {
      was.removeListener(_changed);
      _status.addListener(_changed);
      _sync();
    }
  }

  @override
  void dispose() {
    _status.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _sync();
    setState(() {});
  }

  // The timer runs exactly while a step is open and the line is visible.
  void _sync() {
    final want = _visible && _status.value != null;
    if (want && _tick == null) {
      _tick = Timer.periodic(Motion.tick, (_) {
        if (mounted) setState(() {});
      });
    } else if (!want) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _status.value;
    if (step == null) return const SizedBox.shrink();
    final secs = ((widget.now ?? DateTime.now)()
            .difference(step.startedAt)
            .inSeconds)
        .clamp(0, 1 << 31);
    final elapsed = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    return Padding(
      padding: widget.padding,
      child: Text(
        '${step.label} · $elapsed',
        key: const ValueKey('calc-status-line'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: F.cap.copyWith(color: P.of(context).ink3),
      ),
    );
  }
}
