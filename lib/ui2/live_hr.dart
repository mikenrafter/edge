// The heart rate arriving RIGHT NOW.
//
// Live HR is not a workout-only quantity, but the stream is not free either:
// the screen hosting this card owns the realtime-HR stream while it is mounted
// (`AppState.retainLiveHrView` / `releaseLiveHrView`, discussion #287), so a
// beat is a second old while someone is looking at it and the band goes quiet
// again when they leave. It was simply never surfaced outside the workout
// screen.
//
// THE RULES THIS FILE HOLDS:
//
//   · It OWNS NO TIME. The first version ran a `Timer.periodic` and a heart
//     that pulsed at the measured rate off a repeating controller — which the
//     design-system tests correctly rejected: an endless loop cannot be stopped
//     by the reduced-motion gate, and raw `Duration`s bypass `motion()`. The
//     deeper problem was architectural: the trace also died every time the
//     screen closed. The buffer lives on [AppState] now and this is a pure
//     renderer.
//   · The trace is READINGS, not seconds, and says so. Samples arrive when the
//     band delivers them, so calling it "the last 90 seconds" would be a claim
//     about spacing nothing here guarantees.
//   · Absence states its reason and never a number. `AppState.liveHr` returns
//     null past [AppState.liveHrMaxAge], so an unworn band, a dropped link and
//     a backgrounded HR-only downgrade all arrive as null — and each gets the
//     sentence that is true for it.
//   · It repaints ALONE. A 1 Hz stream hung off a `watch` in a parent would
//     rebuild that whole tree once a second for the life of the connection.

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'profile/devices.dart'
    show HealthSource, deviceIdOf, liveSources, rankSources;
import 'ui2.dart';

/// The tap's cycling rule: the next streaming device after [current] in
/// [ranked]'s order, wrapping — a two-device tap is a toggle, a three-device
/// tap is a rotation. Only a device [AppState.liveHrDeviceId] would accept:
/// streaming, and not a flag-off strap.
String? _nextDevice(AppState app, List<HealthSource> ranked, String? current) {
  final ids = [
    for (final s in ranked)
      // Resolved once and skipped when null (the phone has no `device` row),
      // rather than force-unwrapped after a trace lookup on that same null.
      if (deviceIdOf(s) case final id?)
        if (app.liveHrSelectable(id)) id,
  ];
  if (ids.isEmpty) return null;
  final i = current == null ? -1 : ids.indexOf(current);
  return ids[(i + 1) % ids.length];
}

/// The live reading as a card: the number, and the recent readings behind it.
class LiveHrCard extends StatelessWidget {
  /// The real one: reads the live stream off [AppState].
  const LiveHrCard({super.key})
      : _hr = null,
        _trace = null,
        _preview = false;

  /// A fixed reading, for the gallery. The gallery has no band, no stream and
  /// no Provider above it, and a card that reached for one would either throw
  /// there or force every caller to thread state through. This is the same
  /// widget with its inputs handed to it.
  const LiveHrCard.preview({super.key, required int hr, required List<int> trace})
      : _hr = hr,
        _trace = trace,
        _preview = true;

  final int? _hr;
  final List<int>? _trace;
  final bool _preview;

  static const _fixUnpaired = 'Pair one from Profile to read live beats.';
  static const _fixDisconnected =
      'The app connects when you open it with the band in range. '
      'Live beats need that connection.';

  static String _caption(String? saved, int n, int lo, int hi) =>
      'The last $n readings, $lo to $hi bpm. ${saved ?? _notSavedEn}';
  static const _notSavedEn = 'The live stream is not saved.';

  /// ONE LAYOUT FOR EVERY STATE. The header slot, the 56 pt plot slot with its
  /// key row, and the caption slot are built the same way whether the card has
  /// no band, no beat, one beat or a chart; only what is drawn in them differs.
  /// The card's height therefore comes from the layout, at any text scale and
  /// in any language, and cannot differ between states.
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final hr = _preview ? _hr : c.select<AppState, int?>((a) => a.liveHr);
    // SELECTED, not read: with no reading the only thing this widget watched
    // was `liveHr`, which stays null through both pairing and connecting — so
    // the card went on saying "No band is paired" after the band was paired
    // and connected. These are what change in that state.
    final bool paired, connected;
    if (_preview || hr != null) {
      paired = connected = true;
    } else {
      paired = c.select<AppState, bool>((a) => a.isPaired);
      connected = c.select<AppState, bool>((a) => a.isConnected);
    }

    // A REVISION, not the length. Length is pinned at the cap once the buffer
    // is full, so watching it drew the first 90 readings and then froze.
    List<int> trace = const [];
    if (hr != null) {
      if (_preview) {
        trace = _trace ?? const [];
      } else {
        c.select<AppState, int>((a) => a.liveHrTraceRev);
        trace = c.read<AppState>().liveHrTrace();
      }
    }
    final hasChart = trace.length > 2;
    final live = [for (final v in trace) v.toDouble()];
    final saved = l?.liveHrStreamNotSaved;
    final notSaved = saved ?? _notSavedEn;
    final why = _absenceMessage(paired: paired, connected: connected);
    final waiting = hr != null || (paired && connected);
    final caption = hasChart
        ? _caption(saved, trace.length, trace.reduce(math.min), trace.reduce(math.max))
        : hr != null || waiting
            ? notSaved
            : !paired
                ? _fixUnpaired
                : _fixDisconnected;
    final waitingLabel =
        l?.liveHrWaitingSemantics ?? 'Live heart rate chart, waiting for live data';
    // Same cells as the chart's own key row, with no value in them.
    final keys = [
      ChartKey.slots('Heart rate (bpm)', C.red, live, (i, v) => '${v.round()} bpm'),
    ];
    String? ago(double at) {
      final n = live.length - 1 - ChartScrub.slotAt(live.length, at);
      return n == 0 ? 'Now' : '$n readings ago';
    }

    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // At 3.1x text an n48 number plus a pill does not fit a phone width, so
          // the number is allowed to scale down inside the space that is left
          // rather than the row overflowing. The pill keeps its size: it is two
          // short words and shrinking it is how a label becomes unreadable.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(LucideIcons.heart, size: 26, color: p.on(C.red)),
              const SizedBox(width: S.x3),
              Expanded(
                flex: 2,
                // A FIXED slot height: FittedBox shrinks its child to fit the
                // width, and a wider number shrinks further, which would make
                // the header (and the card) a different height for "61" than
                // for no number at all. The slot is one number line tall at
                // this text scale, whatever is in it.
                child: SizedBox(
                  height: _numberLine(c),
                  child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      // No number yet: a zero-width glyph in the same style, so
                      // the slot has the number's height and shows nothing.
                      Text(hr == null ? '\u200B' : '$hr',
                          style: F.n48.copyWith(color: p.ink)),
                      const SizedBox(width: S.x2),
                      Text(
                        hr == null
                            ? '\u200B'
                            : (l?.activityLiveBpmUnit ?? 'bpm'),
                        style: F.body.copyWith(color: p.ink3),
                      ),
                    ],
                  ),
                ),
                ),
              ),
              const SizedBox(width: S.x2),
              // WHOSE PULSE THIS IS, only when two devices are streaming. Below
              // that the row is byte-identical to today's: same Pill, same
              // position, no Pressable in the tree at all.
              // Flexible: a long label (Russian, 3.1x) shrinks the pill's text
              // instead of overflowing the row.
              Flexible(
                child: (!_preview && c.select<AppState, bool>((a) => a.liveHrMultiDevice))
                ? Builder(
                  builder: (c) {
                    final app = c.read<AppState>();
                    final ranked = rankSources(liveSources(app));
                    final id = app.liveHrDeviceId;
                    final source = id == null ? null
                        : ranked.firstWhereOrNull((s) => deviceIdOf(s) == id);
                    final label = source?.displayName(c) ?? (l?.devicesLive ?? 'LIVE');
                    return Pressable(
                      onTap: () => app.showLiveHrFrom(_nextDevice(app, ranked, id)),
                      semanticLabel:
                          l?.liveHrShowingDeviceSemantics(label) ??
                          'Showing $label. Tap to switch device.',
                      child: Pill(label, C.red, icon: LucideIcons.radio),
                    );
                  },
                )
              : Pill(l?.devicesLive ?? 'LIVE', C.red, icon: LucideIcons.radio),
              ),
            ],
          ),
          const SizedBox(height: S.x3),
          if (hasChart)
            // Bare scrub: no frame, so it draws its own key row under the trace.
            // The 56 pt belongs to the trace alone, not to the row beneath it.
            ChartScrub(
              label: 'Live heart rate',
              // The stream carries no timestamps, so the position is "how many
              // readings ago", counted from the newest.
              time: ago,
              keys: keys,
              child: SizedBox(
                height: 56,
                child: CustomPaint(
                  painter: LineChart(live, C.red, fill: false),
                  size: Size.infinite,
                ),
              ),
            )
          else
            // The same plot slot and key row, nothing scrubbable in them.
            Semantics(
              container: true,
              explicitChildNodes: true,
              label: waiting ? waitingLabel : why,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 56,
                    child: CustomPaint(
                      painter: _LiveHrSkeleton(p.line, p.track),
                      size: Size.infinite,
                      // With no beat, the reason is stated in the frame.
                      child: hr == null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: S.x2),
                                child: Text(why,
                                    textAlign: TextAlign.center,
                                    style: F.body.copyWith(color: p.ink2)),
                              ),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: S.x2),
                  ExcludeSemantics(
                    child: ChartKeyReadout.of(
                        ChartScrub.resolve(keys: keys, time: (_) => null)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: S.x2),
          _CaptionSlot(
            text: caption,
            style: F.over.copyWith(color: p.ink3),
            // The tallest text this slot can hold, so no state is taller.
            reserve: [
              _caption(saved, 90, 100, 200),
              notSaved,
              _fixUnpaired,
              _fixDisconnected,
            ],
          ),
        ],
      ),
    );
  }

  /// One line of the big number, at the current text scale.
  static double _numberLine(BuildContext c) {
    final tp = TextPainter(
        text: TextSpan(text: '0', style: F.n48),
        textDirection: Directionality.of(c),
        textScaler: MediaQuery.textScalerOf(c))
      ..layout();
    final h = tp.height;
    tp.dispose();
    return h;
  }

  String _absenceMessage({required bool paired, required bool connected}) =>
      !paired
          ? 'No band is paired.'
          : !connected
              ? 'Your band is not connected.'
              : 'No beat in the last ${AppState.liveHrMaxAge.inSeconds} seconds.';
}

/// A caption whose height is the tallest of [reserve] at this width and text
/// scale, so changing the words (or the numbers in them) moves nothing.
class _CaptionSlot extends StatelessWidget {
  const _CaptionSlot({required this.text, required this.style, required this.reserve});
  final String text;
  final TextStyle style;
  final List<String> reserve;

  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (c, box) {
        final scaler = MediaQuery.textScalerOf(c);
        final dir = Directionality.of(c);
        var h = 0.0;
        for (final s in reserve) {
          final tp = TextPainter(
              text: TextSpan(text: s, style: style),
              textDirection: dir,
              textScaler: scaler)
            ..layout(maxWidth: box.maxWidth);
          h = math.max(h, tp.height);
          tp.dispose();
        }
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: h),
          child: Text(text, style: style),
        );
      });
}

class _LiveHrSkeleton extends CustomPainter {
  const _LiveHrSkeleton(this.frame, this.axis);
  final Color frame, axis;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = frame..style = PaintingStyle.stroke..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, p);
    final grid = Paint()..color = axis..strokeWidth = 1;
    for (final y in [size.height / 3, size.height * 2 / 3]) {
      canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), grid);
    }
  }
  @override
  bool shouldRepaint(_LiveHrSkeleton old) => frame != old.frame || axis != old.axis;
}
