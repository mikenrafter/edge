// "As of 08:42" — what a screen says while it still shows the last calculated
// result and a newer one is on the way.
//
// The time is the computed time of the row the screen actually read, handed in
// by `asOfFor` (lib/state/recalc_state.dart), which returns null when there is
// no such row or nothing is being recalculated. Null renders nothing, so a
// screen with no prior result keeps its honest building/empty state instead of
// a made-up time.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/recalc_state.dart';
import 'screens/home_screen.dart' show monthShortName;
import 'theme.dart';

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
  });

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

  @override
  void didUpdateWidget(AsOfHold old) {
    super.didUpdateWidget(old);
    if (!identical(old.shown, widget.shown)) _held = null;
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<RecalcState>(
        valueListenable: recalcOf(context),
        builder: (context, recalc, _) {
          final live = widget.asOf(recalc);
          if (live != null) _held = live;
          final at = live ?? _held;
          if (at == null) return const SizedBox.shrink();
          return widget.builder(context, at);
        },
      );
}

class AsOfLabel extends StatelessWidget {
  const AsOfLabel({super.key, required this.at, this.now});

  /// When the shown result was calculated (local time); null shows nothing.
  final DateTime? at;

  /// Only decides "is it today"; defaults to the wall clock.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final t = at;
    if (t == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final n = now ?? DateTime.now();
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
