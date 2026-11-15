// The Sleep night card (pilot day-timeline spec §2). One layout for every
// state: a status row (icon, title, an always-present subheading, ↻), the two
// time chips with "?", and a bottom row. Changing state changes words and the
// icon, never the card's height; only the person opening a time's wheel
// grows it.

import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoDatePicker, CupertinoDatePickerMode;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../grammar.dart';
import '../theme.dart';
import 'timeline_chart.dart' show AppClockText, ClockText;
import 'timeline_model.dart' show BlockEnd;

enum NightSource { auto, fallback, mine, rejected }

/// What the card shows.
class NightCardModel {
  const NightCardModel({
    required this.source,
    this.recalculating = false,
    this.onset,
    this.wake,
    this.coveredMin,
    this.inBedMin,
    this.changedAt,
  });
  final NightSource source;
  final bool recalculating;
  final DateTime? onset, wake;

  /// Minutes the band recorded inside the window, and the window's length.
  final num? coveredMin, inBedMin;

  /// When the person set the times (source mine).
  final DateTime? changedAt;
}

String _hm(num minutes) {
  final m = minutes.round();
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

/// The status row's title and subheading for [m]. Pure, so every state's
/// wording is testable.
({String title, String sub}) nightStatusText(NightCardModel m, [ClockText clock = const AppClockText()]) {
  if (m.recalculating) {
    return (title: 'Recalculating this night', sub: 'You can keep using the app');
  }
  return switch (m.source) {
    NightSource.auto => (
        title: 'Staged from the signals',
        sub: m.coveredMin != null && m.inBedMin != null
            ? 'Band covered ${_hm(m.coveredMin!)} of ${_hm(m.inBedMin!)} in bed'
            : 'Times from the band\'s signals',
      ),
    NightSource.fallback => (
        title: 'Guessed from heart rate',
        sub: 'No clear sleep signal, check the times',
      ),
    NightSource.mine => (
        title: 'You set these times',
        sub: m.changedAt == null ? 'Changed by you' : 'Changed ${_when(m.changedAt!, clock)}',
      ),
    NightSource.rejected => (
        title: 'Marked as not sleep',
        sub: 'Not counted in your totals',
      ),
  };
}

abstract interface class NightCardListener {
  /// After the person confirmed the dialog.
  void recalculate();
  void notSleep();

  /// Undo a "Not sleep", or Back to automatic: the stored override goes.
  void backToAutomatic();

  /// One end set on its wheel.
  void setEnd(BlockEnd which, DateTime to);
  void openTimeline();
  void openNaps();
}

class NightCard extends StatefulWidget {
  const NightCard({super.key, required this.model, required this.listener,
      this.clock = const AppClockText()});
  final NightCardModel model;
  final NightCardListener listener;
  final ClockText clock;

  static const cardKey = ValueKey('night-card');
  static const dotKey = ValueKey('night-card-recalculating-dot');
  static const iconKey = ValueKey('night-card-icon');
  static const recalcKey = ValueKey('night-card-recalculate');
  static const notSleepKey = ValueKey('night-card-not-sleep');
  static const askKey = ValueKey('night-card-not-sure');
  static ValueKey<String> chipKey(BlockEnd e) => ValueKey('night-card-chip:${e.name}');

  @override
  State<NightCard> createState() => _NightCardState();
}

int _ts(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

String _when(DateTime d, ClockText clock) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
    'Oct', 'Nov', 'Dec'];
  return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}, ${clock.of(_ts(d))}';
}

enum _Ask { recalculate, notSleep }

class _NightCardState extends State<NightCard> {
  BlockEnd? _wheel;
  DateTime? _picked;

  Future<void> _confirm(_Ask ask, {required String title, required String body,
      required String action, required bool danger}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) {
        final p = P.of(c);
        return AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(
              key: ValueKey('night-card-confirm:$action'),
              onPressed: () => Navigator.pop(c, true),
              child: Text(action,
                  style: TextStyle(color: danger ? p.on(C.red) : null, fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    switch (ask) {
      case _Ask.recalculate: widget.listener.recalculate();
      case _Ask.notSleep: widget.listener.notSleep();
    }
  }

  void _askRecalculate() => _confirm(_Ask.recalculate,
        title: 'Recalculate this night?',
        body: 'Stages and scores for this night are worked out again from the band\'s '
            'data. Times you set stay as they are. You can keep using the app while it runs.',
        action: 'Recalculate',
        danger: false,
      );

  void _askNotSleep() => _confirm(_Ask.notSleep,
        title: 'Mark this as not sleep?',
        body: 'This night stops counting toward your sleep totals and scores. '
            'You can undo it from this card.',
        action: 'Not sleep',
        danger: true,
      );

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final m = widget.model;
    final text = nightStatusText(m, widget.clock);
    final rejected = m.source == NightSource.rejected;
    final icon = switch (m.source) {
      NightSource.auto => LucideIcons.wandSparkles,
      NightSource.fallback => LucideIcons.circleHelp,
      NightSource.mine => LucideIcons.userCheck,
      NightSource.rejected => LucideIcons.undo2,
    };
    Widget chip(BlockEnd e, String label, DateTime? t) => Expanded(
          child: Opacity(
            opacity: rejected ? .4 : 1,
            child: Pressable(
              key: NightCard.chipKey(e),
              semanticLabel: '$label ${t == null ? 'not set' : widget.clock.of(_ts(t))}',
              onTap: rejected || t == null
                  ? null
                  : () => setState(() {
                        _wheel = _wheel == e ? null : e;
                        _picked = t;
                      }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2),
                decoration: BoxDecoration(
                  color: p.card2,
                  borderRadius: R.rMd,
                  border: Border.all(
                      color: _wheel == e ? p.on(C.blue) : Colors.transparent, width: 1.5),
                ),
                child: Column(children: [
                  Text(label, style: F.over.copyWith(color: p.ink3)),
                  Text(t == null ? '—' : widget.clock.of(_ts(t)),
                      style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        );
    final left = switch (m.source) {
      NightSource.mine => TextButton(
          key: const ValueKey('night-card-back-to-auto'),
          onPressed: widget.listener.backToAutomatic,
          child: const Text('Back to automatic')),
      NightSource.rejected => TextButton(
          key: const ValueKey('night-card-undo'),
          onPressed: widget.listener.backToAutomatic,
          child: Text('Undo', style: TextStyle(color: p.on(C.green), fontWeight: FontWeight.w700))),
      _ => Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x3),
          child: Text('Tap a time to change it', style: F.cap.copyWith(color: p.ink3))),
    };
    return Surface(
      key: NightCard.cardKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // The icon is centred on the two-line text block beside it.
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
            alignment: Alignment.center,
            child: m.recalculating
                ? const _PulseDot(key: NightCard.dotKey)
                : Icon(icon, key: NightCard.iconKey, size: 18, color: p.ink2),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(text.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
              Text(text.sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: F.cap.copyWith(color: p.ink3)),
            ]),
          ),
          Pressable(
            key: NightCard.recalcKey,
            semanticLabel: 'Recalculate this night',
            onTap: _askRecalculate,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
              alignment: Alignment.center,
              child: Icon(LucideIcons.refreshCw, size: 16, color: p.ink2),
            ),
          ),
        ]),
        const SizedBox(height: S.x3),
        Row(children: [
          chip(BlockEnd.start, 'Fell asleep', m.onset),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x2),
            child: Icon(LucideIcons.arrowRight, size: 14, color: p.ink3),
          ),
          chip(BlockEnd.end, 'Woke', m.wake),
          const SizedBox(width: S.x2),
          Pressable(
            key: NightCard.askKey,
            semanticLabel: 'Not sure? Open the sleep timeline',
            onTap: widget.listener.openTimeline,
            child: Container(
              width: 40,
              height: 48,
              decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
              alignment: Alignment.center,
              child: Text('?',
                  style: F.head.copyWith(color: p.on(C.blue), fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
        if (_wheel != null) _wheelPanel(c, p),
        const SizedBox(height: S.x1),
        SizedBox(
          height: 44,
          child: Row(children: [
            Expanded(child: Align(alignment: Alignment.centerLeft,
                child: FittedBox(fit: BoxFit.scaleDown, child: left))),
            if (!rejected)
              TextButton(
                key: NightCard.notSleepKey,
                onPressed: _askNotSleep,
                child: Text('Not sleep',
                    style: TextStyle(color: p.on(C.red), fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
        Divider(height: 1, color: p.line),
        InkWell(
          key: const ValueKey('night-card-naps'),
          onTap: widget.listener.openNaps,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: S.x3),
            child: Row(children: [
              Text('Naps', style: F.body.copyWith(color: p.ink)),
              const Spacer(),
              Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _wheelPanel(BuildContext c, P p) {
    final e = _wheel!;
    final start = _picked ?? DateTime.now();
    return Padding(
      padding: const EdgeInsets.only(top: S.x2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 132,
          child: CupertinoDatePicker(
            key: ValueKey('night-card-wheel:${e.name}'),
            mode: CupertinoDatePickerMode.time,
            initialDateTime: start,
            minuteInterval: 1,
            onDateTimeChanged: (d) => _picked = d,
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => setState(() => _wheel = null), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('night-card-wheel-set'),
            onPressed: () {
              final picked = _picked;
              setState(() => _wheel = null);
              if (picked != null) widget.listener.setEnd(e, picked);
            },
            child: Text('Set', style: TextStyle(color: p.on(C.blue), fontWeight: FontWeight.w700)),
          ),
        ]),
      ]),
    );
  }
}

/// The recalculating mark: a green dot whose lightness pulses. Not a spinner.
class _PulseDot extends StatefulWidget {
  const _PulseDot({super.key});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();
  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return AnimatedBuilder(
      animation: _a,
      builder: (c, _) {
        // .35 -> 1 -> .35 over one period: lightness, not motion.
        final k = .35 + .65 * (.5 - .5 * math.cos(_a.value * 2 * math.pi));
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color.lerp(p.card2, p.on(C.green), k),
          ),
        );
      },
    );
  }
}
