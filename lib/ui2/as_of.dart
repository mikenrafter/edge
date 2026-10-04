// "As of 08:42" — what a screen says while it still shows the last calculated
// result and a newer one is on the way.
//
// The time is the computed time of the row the screen actually read, handed in
// by `asOfFor` (lib/state/recalc_state.dart), which returns null when there is
// no such row or nothing is being recalculated. Null renders nothing, so a
// screen with no prior result keeps its honest building/empty state instead of
// a made-up time.
//
// The same label also carries the staleness line: when it says what recordings
// the shown result covers ("Updated 08:42 · recordings through 08:36") and, if
// newer recordings exist and derive work is held, why ("Paused during workout").
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/recalc_state.dart';
import 'screens/home_screen.dart' show monthShortName;
import 'theme.dart';

export '../state/recalc_state.dart' show StaleHold, staleHoldOf;

/// "Updated 08:42 · recordings through 08:36 · Paused during workout".
///
/// [updatedAt] is the served row's `computed_at`; without it there is no line.
/// [recordingsThrough] is the newest recording that result covers. The reason
/// is said only when [hold] is set AND both recording times are known AND the
/// newest recording is strictly after what the result covers: otherwise there
/// is nothing stale to explain, or no way to know. A missing field drops its
/// part; no time is made up. Local 24 h time; a stamp from another local day
/// than [now] carries its date.
String? stalenessText({
  DateTime? updatedAt,
  DateTime? recordingsThrough,
  DateTime? newestRecording,
  StaleHold? hold,
  DateTime? now,
  AppLocalizations? l,
}) {
  final u = updatedAt;
  if (u == null) return null;
  final n = now ?? DateTime.now();
  String stamp(DateTime at) {
    final t = at.toLocal();
    final time = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    if (t.year == n.year && t.month == n.month && t.day == n.day) return time;
    final date = '${t.day} ${monthShortName(t.month, l)}';
    return l?.asOfDateTime(date, time) ?? '$date, $time';
  }

  // The words are English literals until the ARB keys land (lib/l10n).
  final through = recordingsThrough;
  final newest = newestRecording;
  return [
    'Updated ${stamp(u)}',
    if (through != null) 'recordings through ${stamp(through)}',
    if (hold != null &&
        through != null &&
        newest != null &&
        newest.isAfter(through))
      switch (hold) {
        StaleHold.workout => 'Paused during workout',
        StaleHold.sync => 'Waiting for sync to finish',
        StaleHold.background => 'Paused in the background',
      },
  ].join(' · ');
}

final ValueNotifier<RecalcState> _idle =
    ValueNotifier<RecalcState>(RecalcState.idle);

/// A reader shape's `computed_at` (epoch ms) as a time; null when absent, so no
/// label is ever made from nothing.
DateTime? computedAtOf(Object? ms) =>
    ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;

/// The running pass, for a `ValueListenableBuilder` that feeds `asOfFor`. A
/// screen with no AppState above it (a golden, the gallery) gets one that never
/// changes, so it renders exactly what it was handed.
ValueListenable<RecalcState> recalcOf(BuildContext context) {
  try {
    return context.read<AppState>().recalc;
  } catch (_) {
    return _idle;
  }
}

/// The "As of" label for one shown result, wired to the running pass.
///
/// [asOf] is the screen's own `asOfFor(...)` for the result it shows; [shown] is
/// that result's identity (the loaded object), which changes when a reload
/// commits.
///
/// WHY IT HOLDS. A day leaves the pass when its row is committed, a moment
/// before the screen's reload lands. For that gap the screen still holds the
/// OLD row, and dropping the label then would pass it off as fresh. So the label
/// stays until [shown] is replaced by the reload — whose own `asOfFor` decides
/// again (still recalculating -> label, done -> none). It appears and clears
/// without a database read: it listens to the pass, not to the data.
class AsOfHold extends StatefulWidget {
  const AsOfHold({
    super.key,
    required this.shown,
    required this.asOf,
    required this.builder,
    this.day,
    this.computedAt,
  });

  /// The day the shown result is for, and when its row was computed. With both,
  /// the label also follows the staleness rule: it shows (and says why) when
  /// newer recordings exist than the result covers and derive work is held, and
  /// it says what the result covers while a pass recalculates it. Without them
  /// it is only the "As of" label of a running pass.
  final String? day;
  final DateTime? computedAt;

  final Object? shown;
  final DateTime? Function(RecalcState recalc) asOf;

  /// Places the label (`AsOfLabel(at: at)`); only called with a time, so
  /// whatever it adds around the label is absent while there is none.
  final Widget Function(BuildContext context, DateTime at) builder;

  @override
  State<AsOfHold> createState() => _AsOfHoldState();
}

class _AsOfHoldState extends State<AsOfHold> {
  DateTime? _held;

  /// What the shown day's result covers, read once per load of that day. Null
  /// until read, and when it is unknown.
  DateTime? _through;

  AppState? _app() {
    try {
      return context.read<AppState>();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadThrough();
  }

  @override
  void didUpdateWidget(AsOfHold old) {
    super.didUpdateWidget(old);
    if (!identical(old.shown, widget.shown)) _held = null;
    // Another day's coverage is not this day's.
    if (old.day != widget.day) _through = null;
    if (!identical(old.shown, widget.shown) || old.day != widget.day) {
      _loadThrough();
    }
  }

  void _loadThrough() {
    final day = widget.day;
    final repo = day == null || widget.computedAt == null ? null : _app()?.repo;
    if (day == null || repo == null) return;
    final shown = widget.shown;
    final Future<DateTime?> read;
    try {
      read = repo.dayRecordingsThrough(day);
    } catch (_) {
      return; // a repository that cannot say: the line stays "As of"
    }
    read.then((at) {
      if (!mounted || !identical(shown, widget.shown) || day != widget.day) {
        return;
      }
      if (at != _through) setState(() => _through = at);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    // The hold and, only while one is on, the newest recording: the line
    // follows the scheduler, not the ~1 Hz AppState tick and not the database.
    (StaleHold?, DateTime?) heldNow = (null, null);
    if (widget.day != null && _app() != null) {
      heldNow = context.select<AppState, (StaleHold?, DateTime?)>((a) {
        final h = a.staleHold;
        return (h, h == null ? null : a.lastRecordAt);
      });
    }
    final (hold, newest) = heldNow;
    return ValueListenableBuilder<RecalcState>(
      valueListenable: recalcOf(context),
      builder: (context, recalc, _) {
        final live = widget.asOf(recalc);
        if (live != null) _held = live;
        final through = _through;
        final pausedAt = widget.computedAt;
        final newer = hold != null &&
            pausedAt != null &&
            through != null &&
            newest != null &&
            newest.isAfter(through);
        final at = live ?? _held ?? (newer ? pausedAt : null);
        if (at == null) return const SizedBox.shrink();
        final label = widget.builder(context, at);
        if (through == null) return label;
        return _StaleInfo(
            recordingsThrough: through,
            newestRecording: newest,
            hold: hold,
            child: label);
      },
    );
  }
}

/// What [AsOfHold] knows beyond the time, for the [AsOfLabel] its builder
/// places: an explicit field on the label wins.
class _StaleInfo extends InheritedWidget {
  const _StaleInfo({
    required this.recordingsThrough,
    required this.newestRecording,
    required this.hold,
    required super.child,
  });

  final DateTime recordingsThrough;
  final DateTime? newestRecording;
  final StaleHold? hold;

  static _StaleInfo? maybeOf(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<_StaleInfo>();

  @override
  bool updateShouldNotify(_StaleInfo old) =>
      old.recordingsThrough != recordingsThrough ||
      old.newestRecording != newestRecording ||
      old.hold != hold;
}

class AsOfLabel extends StatelessWidget {
  const AsOfLabel({
    super.key,
    required this.at,
    this.now,
    this.recordingsThrough,
    this.newestRecording,
    this.hold,
  });

  /// When the shown result was calculated (local time); null shows nothing.
  final DateTime? at;

  /// What the result covers, the newest recording we hold and what is held:
  /// with [recordingsThrough] or [hold] the label is the staleness line
  /// ([stalenessText]) instead of "As of". [AsOfHold] hands them to the label
  /// it places; a label placed on its own can pass them itself.
  final DateTime? recordingsThrough;
  final DateTime? newestRecording;
  final StaleHold? hold;

  /// Only decides "is it today"; defaults to the wall clock.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final t = at;
    if (t == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final n = now ?? DateTime.now();
    final info = _StaleInfo.maybeOf(context);
    final through = recordingsThrough ?? info?.recordingsThrough;
    final holdNow = hold ?? info?.hold;
    if (through != null || holdNow != null) {
      final line = stalenessText(
          updatedAt: t,
          recordingsThrough: through,
          newestRecording: newestRecording ?? info?.newestRecording,
          hold: holdNow,
          now: n,
          l: l);
      if (line == null) return const SizedBox.shrink();
      return Semantics(
        label: line,
        excludeSemantics: true,
        child: Text(
          line,
          key: const ValueKey('as-of-label'),
          style: F.cap.copyWith(color: P.of(context).ink3),
        ),
      );
    }
    final time = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    // A result from another local day carries its date: yesterday's row is
    // never passed off as today's.
    final today = t.year == n.year && t.month == n.month && t.day == n.day;
    final date = '${t.day} ${monthShortName(t.month, l)}';
    final text = today
        ? (l?.asOfTime(time) ?? 'As of $time')
        : (l?.asOfDateTime(date, time) ?? 'As of $date, $time');
    final when = today ? time : '$date, $time';
    return Semantics(
      label: l?.asOfSemantics(when) ??
          'Showing results calculated at $when; new results are being calculated',
      excludeSemantics: true,
      child: Text(
        text,
        key: const ValueKey('as-of-label'),
        style: F.cap.copyWith(color: P.of(context).ink3),
      ),
    );
  }
}
