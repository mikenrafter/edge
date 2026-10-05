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
//
// Laid out as sub-tabs (Oct 4): what applies to every gesture (the intro, how
// extra taps are counted) is above the tab row; each gesture is a tab, and
// every tab has the same shape: its name and how to do it, the actions as
// switches, then the links (Haptics, and the Device lab in developer mode).

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../gestures/device_action.dart';
import '../../gestures/ecg_tap_counter.dart';
import '../../gestures/gesture_settings.dart';
import '../../gestures/tap_names.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'device_lab.dart';
import 'haptics_settings.dart' show HapticsSettings;
import 'profile.dart';

/// Where the tab last used is kept: the tap count of the gesture (2 is the
/// plain double tap), in the app prefs with the other UI selections.
const String kGesturesTabPref = 'ui.gestures_tab';

class BandGestures extends StatelessWidget {
  const BandGestures({super.key});

  @override
  Widget build(BuildContext c) {
    // `gestureSettings` is a ChangeNotifier the dispatcher reads live, so the
    // screen listens to the same object rather than keeping its own copy —
    // flipping a switch has to move the thing the band is about to consult.
    final g = c.read<AppState>().gestureSettings;
    final caps = c.caps;
    return ListenableBuilder(
      listenable: g,
      builder: (c, _) => BandGesturesView(
        chosen: g.doubleTapActions,
        supported: g.supported,
        onToggle: g.toggleDoubleTapAction,
        replay: g.replayActions,
        onReplay: g.setReplayHistorical,
        // The row for 2 taps is the switches above; 3–5 are the draft extra-tap
        // counts. More double taps by default on any band; ECG touches are an
        // opt-in on a WHOOP MG.
        ecgSupported: caps.has(Feature.ecgTouchTaps),
        tapMethod: g.tapMethodFor(ecgSupported: caps.has(Feature.ecgTouchTaps)),
        onTapMethod: g.setTapMethod,
        tapActions: {for (var n = 3; n <= 5; n++) n: g.actionsForTaps(n)},
        onTapToggle: (n, a, on) {
          final cur = g.actionsForTaps(n);
          return g.setActionsForTaps(n, on ? {...cur, a} : cur.difference({a}));
        },
        extraTaps: caps.has(Feature.extraTapCounting),
        onHaptics: () => goto(c, const HapticsSettings()),
        devMode: caps.has(Feature.developerMode),
        onDeviceLab: () => goto(c, const DeviceLab()),
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

  /// How extra taps are counted for this band. Null follows the default
  /// (repeated double taps); a band without ECG always counts double taps.
  final TapCountMethod? tapMethod;
  final ValueChanged<TapCountMethod>? onTapMethod;

  /// The pause and touch-window tuning controls moved to the Device lab (8AE),
  /// where they were already shared widgets; this screen draws neither. The
  /// four fields stay so existing construction sites keep compiling.
  final int? repeatWindowMs;
  final ValueChanged<int>? onRepeatWindowMs;

  /// Actions mapped to 3, 4 and 5 taps (8L draft). 2 taps is [chosen].
  final Map<int, Set<DeviceAction>> tapActions;

  /// Flip one action for an n-tap count. Null leaves the rows read-only.
  final Future<void> Function(int taps, DeviceAction, bool)? onTapToggle;

  final EcgTapThresholds? thresholds;
  final ValueChanged<EcgTapThresholds>? onThresholds;

  /// FeatureFlag.tapClassifiers. False hides every extra-tap control (method,
  /// tap counts and the MG note): the screen is then the
  /// plain double-tap action list.
  final bool extraTaps;

  /// Opens the Haptics screen, where the buzzes these gestures play are
  /// chosen (8AI). The row is always drawn; without a callback it is inert.
  final VoidCallback? onHaptics;

  /// Developer mode: a Device lab link under the Haptics one in every tab.
  final bool devMode;
  final VoidCallback? onDeviceLab;

  const BandGesturesView({
    super.key,
    required this.chosen,
    required this.supported,
    this.onToggle,
    this.replay = const {},
    this.onReplay,
    this.ecgSupported = false,
    this.tapMethod,
    this.onTapMethod,
    this.repeatWindowMs,
    this.onRepeatWindowMs,
    this.tapActions = const {},
    this.onTapToggle,
    this.thresholds,
    this.onThresholds,
    this.extraTaps = true,
    this.onHaptics,
    this.devMode = false,
    this.onDeviceLab,
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
    final method = ecgSupported
        ? (tapMethod ?? TapCountMethod.repeat)
        : TapCountMethod.repeat;
    final ecg = method == TapCountMethod.ecg;

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.gesturesNavTitle ?? 'Gestures'),
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
                // How taps beyond the double tap are counted. ECG is dimmed and
                // inert (never hidden) on a band without the sensor.
                if (extraTaps) ...[
                  SettingsAccordion('Count extra taps with',
                      id: 'gestures_extra_taps',
                      children: [
                    _MethodRow(
                      id: 'ecg',
                      title: 'ECG sensor touches',
                      sub: 'Touch the ECG sensor on the band after the double '
                          'tap. WHOOP MG only.',
                      selected: ecg,
                      enabled: ecgSupported,
                      onTap: () => onTapMethod?.call(TapCountMethod.ecg),
                    ),
                    _MethodRow(
                      id: 'repeat',
                      title: 'More double taps',
                      sub: 'Double tap again before the pause ends. Works on '
                          'every band.',
                      selected: !ecg,
                      enabled: true,
                      onTap: () => onTapMethod?.call(TapCountMethod.repeat),
                    ),
                  ]),
                  Section(
                    'What needs a WHOOP MG',
                    Surface(
                      child: Text(kExtendedGesturesNote,
                          style: F.body.copyWith(color: p.ink2, height: 1.4)),
                    ),
                  ),
                ],
                // 2 taps is the plain double tap; there is no 1-tap tab. The
                // rest are a DRAFT: touches of the ECG sensor after the double
                // tap, or more double taps in a row. One mapping serves both:
                // the slot for 3 taps is the slot for 2 double taps. Without
                // extra taps there is one gesture, so no tab row.
                if (extraTaps)
                  _GestureTabs(
                    items: [
                      for (var n = 2; n <= 5; n++) _tabLabel(n, ecg),
                    ],
                    semanticLabels: [
                      for (var n = 2; n <= 5; n++)
                        '${_name(l, n, ecg)}, gesture',
                    ],
                    body: (c, n) =>
                        _tabBody(c, n, ecg, offered, noPhoneActions, S.x5),
                  )
                else
                  _tabBody(c, 2, ecg, offered, noPhoneActions, S.x3),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// One gesture's tab. Every tab has this shape: the name and how to do it,
  /// the actions as switches, then the links at the bottom. [top] is the gap
  /// above the first card: under a tab row it is S.x5, what Health and Workout
  /// leave under theirs.
  Widget _tabBody(BuildContext c, int taps, bool ecg, List<DeviceAction> offered,
      bool noPhoneActions, double top) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final on = taps == 2 ? chosen : (tapActions[taps] ?? const <DeviceAction>{});
    return Column(
      key: ValueKey('gestures-tab-body:$taps'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(top: top),
          child: Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(_name(l, taps, ecg),
                              key: const ValueKey('gestures-tab-name'),
                              style: F.body.copyWith(
                                  color: p.ink, fontWeight: FontWeight.w600)),
                        ),
                        if (taps > 2) ...[
                          const SizedBox(width: S.x2),
                          Text('Draft',
                              style: F.over.copyWith(
                                  color: p.on(C.orange),
                                  fontWeight: FontWeight.w600)),
                        ],
                      ]),
                      Text(_how(taps, ecg),
                          key: const ValueKey('gestures-tab-how'),
                          style: F.over.copyWith(color: p.ink3)),
                    ]),
              ),
              for (final a in offered) ...[
                Divider(color: p.line, height: 1),
                SwitchRow(
                  a.localizedLabel(c),
                  on.contains(a),
                  taps == 2
                      ? (onToggle == null ? null : (v) => onToggle!(a, v))
                      : (onTapToggle == null
                          ? null
                          : (v) => onTapToggle!(taps, a, v)),
                  sub: a.localizedBlurb(c),
                ),
                // Directly under the one action that can be replayed safely,
                // on the plain double tap alone: a counted tap is always live.
                // Always drawn; inert and dimmed while the action itself is
                // off (8K).
                if (taps == 2 && a.supportsHistoricalReplay) ...[
                  Divider(color: p.line, height: 1),
                  SwitchRow(
                    l?.gesturesReplayTitle ??
                        'Also run for taps replayed from history',
                    replay.contains(a),
                    onReplay == null ? null : (v) => onReplay!(a, v),
                    enabled: chosen.contains(a),
                    sub: !chosen.contains(a)
                        ? 'Turn on ${a.localizedLabel(c)} first'
                        : l?.gesturesReplaySub ??
                            'A tap the band delivers late is still stamped with the '
                                'minute and day it happened. Other actions never run for '
                                'a late tap.',
                  ),
                ],
              ],
            ]),
          ),
        ),
        if (noPhoneActions)
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
        // The links, each its own card with the page's section gap above it.
        Padding(
          padding: const EdgeInsets.only(top: S.x3),
          child: Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: SetRow(
              LucideIcons.vibrate,
              C.purple,
              'Haptics',
              key: const ValueKey('gestures-open-haptics'),
              sub: 'The buzzes these gestures play',
              onTap: onHaptics,
            ),
          ),
        ),
        if (devMode)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Surface(
              pad: const EdgeInsets.symmetric(horizontal: S.x4),
              child: SetRow(
                LucideIcons.flaskConical,
                C.purple,
                'Device lab',
                key: const ValueKey('gestures-open-device-lab'),
                sub: 'Try gestures the band does not report on its own',
                onTap: onDeviceLab,
              ),
            ),
          ),
      ],
    );
  }

  // The gesture's name: the plain double tap, then the count's own name. The
  // ECG count's name (8AK C) is the plural message, or the same English from
  // the plain helper where no localizations are in the tree.
  static String _name(AppLocalizations? l, int n, bool ecg) => n == 2
      ? 'Double tap'
      : ecg
          ? (l?.gestureEcgTapName(n - 2) ?? ecgTapCountName(n))
          : '${n - 1} double taps';

  // What fits a 360 pt tab; the full name is the screen reader's label.
  static String _tabLabel(int n, bool ecg) => n == 2
      ? 'Double tap'
      : ecg
          ? '+${n - 2} ECG'
          : '×${n - 1}';

  static String _how(int n, bool ecg) {
    if (n == 2) return 'Tap the band twice.';
    if (ecg) {
      final k = n - 2;
      return 'Double tap, then touch the ECG sensor '
          '${k == 1 ? 'once' : '$k times'}.';
    }
    return 'Double tap ${n - 1} times in a row before the pause ends.';
  }
}

/// The tab row and the body of the selected tab. The tab is remembered across
/// visits; one that is not offered (or never stored) opens the double tap.
class _GestureTabs extends StatefulWidget {
  const _GestureTabs(
      {required this.items, required this.semanticLabels, required this.body});

  final List<String> items, semanticLabels;
  final Widget Function(BuildContext context, int taps) body;

  @override
  State<_GestureTabs> createState() => _GestureTabsState();
}

class _GestureTabsState extends State<_GestureTabs> {
  late int _n = _remembered();

  int _remembered() {
    final n = int.tryParse(Prefs.getString(kGesturesTabPref, ''));
    return n != null && n >= 2 && n < 2 + widget.items.length ? n : 2;
  }

  void _select(int n) {
    if (n == _n) return;
    setState(() => _n = n);
    // A UI selection: a write that did not land only costs the memory of it.
    Prefs.setString(kGesturesTabPref, '$n');
  }

  @override
  Widget build(BuildContext c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: S.x4),
            child: SubTabs(
              widget.items,
              _n - 2,
              (i) => _select(i + 2),
              color: C.blue,
              dense: true,
              itemKeys: [
                for (var n = 2; n < 2 + widget.items.length; n++)
                  ValueKey('gestures-tab:$n'),
              ],
              semanticLabels: widget.semanticLabels,
            ),
          ),
          widget.body(c, _n),
        ],
      );
}

/// One choice in "Count extra taps with". Deliberately not a [SwitchRow]: it is
/// one of two, and a disabled choice stays visible and dimmed with its reason.
class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.id,
    required this.title,
    required this.sub,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String id, title, sub;
  final bool selected, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final row = Pressable(
      key: ValueKey('tap-method:$id'),
      onTap: enabled ? onTap : null,
      semanticLabel: '$title. $sub',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: F.body.copyWith(color: p.ink)),
              Text(sub, style: F.over.copyWith(color: p.ink3)),
              if (!enabled)
                Text('This band has no ECG sensor',
                    style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          const SizedBox(width: S.x2),
          if (selected)
            Icon(LucideIcons.check, size: 18, color: p.on(C.blue))
          else
            const SizedBox(width: 18),
        ]),
      ),
    );
    return enabled ? row : Opacity(opacity: kDisabledOpacity, child: row);
  }
}
