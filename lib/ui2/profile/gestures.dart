// What a double-tap on the band does.
//
// The engine for this shipped a long time ago — the event decode, the recency
// and debounce guards, the persisted mapping, the native channel — and then the
// screen that sets it died with the old `lib/ui` tree. So the mapping sat on its
// `none` default with nothing able to change it: a feature that ran on every
// live event and could never do anything. This is the missing half.
//
// The list is not a fixed menu. It is whatever THIS phone said it can actually
// do — `GestureSettings.supported`, seeded from `DeviceActions.capabilities()`.
// An action drawn here and then silently doing nothing is worse than one that
// was never offered: iOS cannot touch system volume or a third-party player, and
// only Android has the Tasker broadcast, so on an iPhone those are simply not in
// the list. When native answers with nothing at all, the phone actions are
// absent AND SAY SO, rather than leaving a gap to guess at.
//
// Several actions can be on at once. There is no "do nothing" row: every action
// off IS the off state, and the copy says so.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../gestures/device_action.dart';
import '../../gestures/ecg_tap_counter.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'device_lab.dart';
import 'profile.dart';

class BandGestures extends StatelessWidget {
  const BandGestures({super.key});

  @override
  Widget build(BuildContext c) {
    // `gestureSettings` is a ChangeNotifier the dispatcher reads live, so the
    // screen listens to the same object rather than keeping its own copy —
    // flipping a switch has to move the thing the band is about to consult.
    final g = c.read<AppState>().gestureSettings;
    return ListenableBuilder(
      listenable: g,
      builder: (c, _) => BandGesturesView(
        chosen: g.doubleTapActions,
        supported: g.supported,
        onToggle: g.toggleDoubleTapAction,
        replay: g.replayActions,
        onReplay: g.setReplayHistorical,
        // The row for 2 taps is the switches above; 3–5 are the draft ECG-touch
        // counts, only meaningful on a WHOOP MG.
        ecgSupported: c.read<AppState>().pairedIsMaverick,
        tapActions: {for (var n = 3; n <= 5; n++) n: g.actionsForTaps(n)},
        onTapToggle: (n, a, on) {
          final cur = g.actionsForTaps(n);
          return g.setActionsForTaps(n, on ? {...cur, a} : cur.difference({a}));
        },
        thresholds: g.ecgTapThresholds,
        onThresholds: g.setEcgTapThresholds,
      ),
    );
  }
}

class BandGesturesView extends StatelessWidget {
  /// The actions that are on. Empty is the off state.
  final Set<DeviceAction> chosen;

  /// What this phone can do. Contains [DeviceAction.none] but it is never drawn.
  final Set<DeviceAction> supported;

  final void Function(DeviceAction, bool)? onToggle;

  /// Actions that also run for a tap the band delivered late. Only
  /// [DeviceAction.markMoment] can be replayed safely; the row for it is the
  /// only replay control drawn.
  final Set<DeviceAction> replay;

  final void Function(DeviceAction, bool)? onReplay;

  /// A WHOOP MG: the only band whose ECG sensor can be touched to count taps.
  final bool ecgSupported;

  /// Actions mapped to 3, 4 and 5 taps (8L draft). 2 taps is [chosen].
  final Map<int, Set<DeviceAction>> tapActions;

  /// Flip one action for an n-tap count. Null leaves the rows read-only.
  final Future<void> Function(int taps, DeviceAction, bool)? onTapToggle;

  /// The touch windows; the adjusters show only when [onThresholds] is given.
  final EcgTapThresholds? thresholds;
  final ValueChanged<EcgTapThresholds>? onThresholds;

  const BandGesturesView({
    super.key,
    required this.chosen,
    required this.supported,
    this.onToggle,
    this.replay = const {},
    this.onReplay,
    this.ecgSupported = false,
    this.tapActions = const {},
    this.onTapToggle,
    this.thresholds,
    this.onThresholds,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    // Enum order, filtered to this phone: the in-app actions, then whatever the
    // OS offered. `none` is not an action — it has no row.
    final offered = [
      ...DeviceAction.values.where((a) => a.isInApp && supported.contains(a)),
      ...DeviceAction.values.where((a) => a.isNative && supported.contains(a)),
    ];
    final noPhoneActions = !offered.any((a) => a.isNative);

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.gesturesNavTitle ?? 'Double-tap'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Section(
                  l?.gesturesSectionTitle ?? 'Tap the band twice',
                  Surface(
                    child: Text(
                      l?.gesturesSectionBodyMulti ??
                          'Works only while the app is connected and awake. Turn on as many '
                              'actions as you like; with every action off, a double-tap does '
                              'nothing. If you tap while your phone is away, the band stores '
                              'the tap and sends it later. A late tap runs only an action '
                              'that says it can.',
                      style: F.body.copyWith(color: p.ink2, height: 1.4),
                    ),
                  ),
                ),
                settingsGroup(c, l?.gesturesItDoesTitle ?? 'It does', [
                  for (final a in offered) ...[
                    SwitchRow(
                      a.localizedLabel(c),
                      chosen.contains(a),
                      onToggle == null ? null : (v) => onToggle!(a, v),
                      sub: a.localizedBlurb(c),
                    ),
                    // Directly under the one action that can be replayed
                    // safely, and only while it is on.
                    if (a.supportsHistoricalReplay && chosen.contains(a))
                      SwitchRow(
                        l?.gesturesReplayTitle ??
                            'Also run for taps replayed from history',
                        replay.contains(a),
                        onReplay == null ? null : (v) => onReplay!(a, v),
                        sub: l?.gesturesReplaySub ??
                            'A tap the band delivers late is still stamped with the '
                                'minute and day it happened. Other actions never run for '
                                'a late tap.',
                      ),
                  ],
                ]),
                // 2 taps is the switches above; there is no 1-tap row. 3–5 are
                // a DRAFT: touches of the ECG sensor after the double tap.
                settingsGroup(c, 'Tap counts', [
                  _TapCountRow(
                    taps: 2,
                    summary: _summary(chosen),
                    sub: 'The actions above',
                  ),
                  for (final n in const [3, 4, 5])
                    _TapCountRow(
                      taps: n,
                      draft: true,
                      enabled: ecgSupported,
                      summary: _summary(tapActions[n] ?? const {}),
                      sub: 'Touch the ECG sensor after the double tap',
                      onTap: ecgSupported && onTapToggle != null
                          ? () => _pickActions(
                              c, n, offered, tapActions[n] ?? const {})
                          : null,
                    ),
                ]),
                Section(
                  'What needs a WHOOP MG',
                  Surface(
                    child: Text(kExtendedGesturesNote,
                        style: F.body.copyWith(color: p.ink2, height: 1.4)),
                  ),
                ),
                if (onThresholds != null)
                  Section(
                    'Touch windows',
                    Surface(
                      child: EcgThresholdAdjusters(
                        thresholds: thresholds ?? EcgTapThresholds(),
                        onChanged: ecgSupported ? onThresholds : null,
                      ),
                    ),
                  ),
                if (noPhoneActions) ...[
                  const SizedBox(height: S.x5),
                  Section(
                    l?.gesturesNoPhoneActionsTitle ?? 'Nothing on the phone?',
                    Surface(
                      child: Text(
                        l?.gesturesNoPhoneActionsBody ??
                            'Ringing your phone and the flashlight are missing because the app could '
                                'not ask the system what this device allows. Reopen the app to try '
                                'again. The in-app actions above still work.',
                        style: F.body.copyWith(color: p.ink2, height: 1.4),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  static String _summary(Set<DeviceAction> a) =>
      a.isEmpty ? 'Off' : '${a.length} on';

  /// A sheet of the offered actions as check boxes for one tap count. Keeps its
  /// own copy of the set so a tick shows at once; [onTapToggle] persists it.
  Future<void> _pickActions(BuildContext c, int taps,
      List<DeviceAction> offered, Set<DeviceAction> current) {
    final p = P.of(c);
    return showModalBottomSheet<void>(
      context: c,
      backgroundColor: p.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        var on = {...current};
        return StatefulBuilder(
          builder: (sheet, setSheet) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x2),
                  child: Text('$taps taps does',
                      style: F.head.copyWith(color: p.ink)),
                ),
                for (final a in offered)
                  CheckboxListTile(
                    value: on.contains(a),
                    title: Text(a.localizedLabel(sheet),
                        style: F.body.copyWith(color: p.ink)),
                    onChanged: (v) {
                      final next = v ?? false;
                      setSheet(() => on = next ? {...on, a} : on.difference({a}));
                      onTapToggle!(taps, a, next);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One row of the tap-count list. Deliberately not a [SwitchRow]: it opens a
/// picker, and a disabled draft row stays visible and dimmed with its reason.
class _TapCountRow extends StatelessWidget {
  const _TapCountRow({
    required this.taps,
    required this.summary,
    required this.sub,
    this.draft = false,
    this.enabled = true,
    this.onTap,
  });

  final int taps;
  final bool draft, enabled;
  final String summary, sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final row = Pressable(
      onTap: enabled ? onTap : null,
      semanticLabel: '$taps taps. $sub',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text('$taps taps', style: F.body.copyWith(color: p.ink)),
                ),
                if (draft) ...[
                  const SizedBox(width: S.x2),
                  Text('Draft',
                      style: F.over.copyWith(
                          color: p.on(C.orange), fontWeight: FontWeight.w600)),
                ],
              ]),
              Text(sub, style: F.over.copyWith(color: p.ink3)),
              if (!enabled)
                Text('This band has no ECG sensor',
                    style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          const SizedBox(width: S.x2),
          Text(summary, style: F.cap.copyWith(color: p.ink3)),
        ]),
      ),
    );
    return enabled ? row : Opacity(opacity: .45, child: row);
  }
}
