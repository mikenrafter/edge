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
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
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

  const BandGesturesView({
    super.key,
    required this.chosen,
    required this.supported,
    this.onToggle,
    this.replay = const {},
    this.onReplay,
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
}
