// BAND NOTIFICATIONS — buzz the strap when a phone app notifies you.
// ANDROID ONLY, and silently absent everywhere else: iOS has no API to observe
// another app's notifications, so there is no "unavailable on this device"
// copy to write.
//
// WHY THIS FILE HAD TO COME BACK. The relay itself never stopped working:
// `AppState` still bootstraps it, and the manifest still declares
// BIND_NOTIFICATION_LISTENER_SERVICE for it. What the UI rebuild deleted was
// every control — so the app shipped a notification-listener permission with
// no way to reach the feature it exists for. A permission a reviewer can read
// in the manifest and a user cannot find in the app is the problem, more than
// the missing feature is.
//
// WHERE THE APP LIST COMES FROM. Apps that have actually posted a notification
// while the listener was running, not the installed set. Enumerating installed
// packages needs QUERY_ALL_PACKAGES, which the sweep removed from the manifest
// with `tools:node="remove"` and called the most policy-expensive permission
// there is — that decision stands. It also happens to be the better list: the
// dozen apps that interrupt you, rather than two hundred to scroll past. The
// cost is that the list starts empty and fills over the first minutes, which
// the empty state says in as many words rather than looking broken.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../haptics/haptic_profile.dart';
import '../../notify/buzz_sequence.dart';
import '../../notify/notification_relay.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'buzz_pattern.dart';
import 'profile.dart' show SetRow, SettingsAccordion, SwitchRow, kDisabledOpacity;
import 'settings.dart' show NotificationSettingsView;

/// One row's worth of the picker.
class RelayApp {
  const RelayApp(this.package, {this.icon, this.on = false});
  final String package;
  final Uint8List? icon;
  final bool on;
}

/// The route. Reads the live [NotificationRelay] off [AppState] and hands
/// [BandNotificationsView] plain values — the view is what the tests pump, and
/// it never asks the platform anything.
class BandNotifications extends StatefulWidget {
  const BandNotifications({super.key});

  @override
  State<BandNotifications> createState() => _BandNotificationsState();
}

class _BandNotificationsState extends State<BandNotifications>
    with WidgetsBindingObserver {
  NotificationRelay get _relay => context.read<AppState>().notificationRelay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system Notification-access page: re-read the real grant
    // rather than trusting what the user said they did.
    if (state == AppLifecycleState.resumed && mounted) {
      _relay.refreshPermission();
    }
  }

  @override
  Widget build(BuildContext c) {
    final relay = _relay;
    return AnimatedBuilder(
      // The wear line follows the band, which AppState announces.
      animation: Listenable.merge([relay, context.read<AppState>()]),
      builder: (c, _) => BandNotificationsView(
        supported: relay.supported,
        enabled: relay.enabled,
        granted: relay.permissionGranted,
        apps: [
          for (final p in relay.seenPackages)
            RelayApp(p, icon: relay.iconFor(p), on: relay.isAppEnabled(p)),
        ],
        channels: relay.controller.channels,
        onChannel: relay.setChannel,
        onEnabled: relay.setEnabled,
        onlyWhileWorn: relay.onlyWhileWorn,
        wearReport: relay.wearReport,
        onOnlyWhileWorn: relay.setOnlyWhileWorn,
        onGrant: relay.requestPermission,
        onApp: relay.setAppEnabled,
        onChannelBuzzPattern: (name) => _pick(
          relay.controller.channels[name] ?? ChannelConfig.forChannel(name),
          (cfg) => relay.setChannel(name, cfg),
        ),
        onAppBuzzPattern: (pkg) {
          final cfg = relay.controller.channels['apps'] ??
              ChannelConfig.forChannel('apps');
          _pick(
            cfg,
            (cfg) => relay.setChannel('apps', cfg),
            pkg: pkg,
          );
        },
      ),
    );
  }

  /// Opens the sheet for a channel's own rhythm, or for [pkg]'s when given, and
  /// writes the take back into [cfg].
  void _pick(
    ChannelConfig cfg,
    void Function(ChannelConfig next) put, {
    String? pkg,
  }) {
    final app = context.read<AppState>();
    showBuzzPatternSheet(
      context,
      initial: pkg == null ? cfg.effectiveSequence : cfg.sequenceForApp(pkg),
      bandConnected: app.engine.isConnected,
      onPlay: app.previewBuzzSequence,
      // The band's measured vocabulary (an MG), none on a 4.0.
      profile: HapticDeviceProfile.forGeneration(app.device.generation),
      onSave: (s) => put(pkg == null
          ? cfg.copyWith(buzzSequence: s)
          : cfg.copyWith(appSequences: {...cfg.appSequences, pkg: s})),
    );
  }
}

/// The screen, as a pure function of its inputs.
class BandNotificationsView extends StatelessWidget {
  const BandNotificationsView({
    super.key,
    this.supported = true,
    this.enabled = false,
    this.granted = false,
    this.apps = const [],
    this.channels = const {},
    this.onEnabled,
    this.onlyWhileWorn = false,
    this.wearReport = 'unknown',
    this.onOnlyWhileWorn,
    this.onGrant,
    this.onApp,
    this.onChannel,
    this.onAppBuzzPattern,
    this.onChannelBuzzPattern,
  });

  final bool supported, enabled, granted;
  final List<RelayApp> apps;

  /// Per-channel policy by name (apps, alarms, calls). Absent means defaults.
  final Map<String, ChannelConfig> channels;
  final void Function(String channel, ChannelConfig next)? onChannel;
  final ValueChanged<bool>? onEnabled;

  /// One setting for the whole relay, and what the band says about being worn
  /// right now (worn, notWorn or unknown).
  final bool onlyWhileWorn;
  final String wearReport;
  final ValueChanged<bool>? onOnlyWhileWorn;
  final VoidCallback? onGrant;
  final void Function(String pkg, bool on)? onApp;

  /// Open the buzz-pattern sheet for one app / for one channel (by name).
  final void Function(String pkg)? onAppBuzzPattern;
  final void Function(String channel)? onChannelBuzzPattern;

  bool get _appsUsable => enabled && granted;

  /// How many apps are actually armed — the one number that says whether the
  /// feature will do anything at all.
  int get _armed => apps.where((a) => a.on).length;

  String get _wearSub => switch ((onlyWhileWorn, wearReport)) {
    (false, _) =>
      'Off. The band buzzes whether or not it is on your wrist.',
    (true, 'worn') => 'On. The band says it is on your wrist.',
    (true, 'notWorn') =>
      'On. The band says it is off your wrist, so nothing buzzes.',
    _ => 'On. This band has not reported wear, so nothing buzzes. '
        'Turn this off to buzz anyway.',
  };

  /// The app list is always drawn. While the relay is off, or Android has not
  /// granted notification access, it is dimmed and inert, and the first row
  /// says which of the two it is waiting for (8K).
  List<Widget> _appRows(BuildContext c, AppLocalizations? l) => [
    SetRow(LucideIcons.listChecks, C.teal,
        l?.bandNotifAppsArmed ?? 'Apps that can buzz',
        enabled: _appsUsable,
        sub: !enabled
            ? 'Turn on the relay first'
            : !granted
                ? 'Grant notification access first'
                : '',
        value: '$_armed',
        chevron: false),
    if (apps.isEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l?.bandNotifEmptyTitle ?? 'No app has notified you yet',
              style: F.body.copyWith(color: P.of(c).ink)),
          // Absence with its reason, not an empty list: this is the cost of
          // not asking for the permission that enumerates every installed
          // app, and it resolves itself within minutes of ordinary use.
          Text(
              l?.bandNotifEmptyBody ??
                  'An app appears here after its first notification while '
                  'the relay is on. That first notification only adds '
                  'the app to the list. Later notifications from it '
                  'can buzz.',
              style: F.over.copyWith(color: P.of(c).ink3)),
        ]),
      )
    else
      for (final a in apps)
        _AppRow(a,
            enabled: _appsUsable,
            onChanged: onApp,
            sequence: (channels['apps'] ?? ChannelConfig.forChannel('apps'))
                .sequenceForApp(a.package),
            onBuzzPattern: onAppBuzzPattern),
  ];

  /// Fallback rhythms for alarm matching, tapped through in place.
  static const _rhythms = [
    ('One short', [0, 250]),
    ('Two long', [0, 400, 100, 400]),
    ('Three short', [0, 150, 100, 150, 100, 150]),
  ];

  /// The policy every channel carries once: Do Not Disturb, vibrate, silent,
  /// phone alert and quiet hours.
  List<Widget> _policyRows(BuildContext c, String name) {
    final cfg = channels[name] ?? ChannelConfig.forChannel(name);
    void put(ChannelConfig next) => onChannel?.call(name, next);
    final quietOn = cfg.quietStartMinute != null && cfg.quietEndMinute != null;
    final rhythm = _rhythms.indexWhere(
        (r) => r.$2.join(',') == cfg.fallbackPattern.join(','));
    return [
      // One relay: this reads On only when the master switch is on too.
      SwitchRow('Relay to the band', cfg.enabled && enabled,
          (v) => put(cfg.copyWith(enabled: v))),
      if (name == 'alarms') ...[
        SwitchRow("Match Android's vibration", cfg.matchHaptics,
            (v) => put(cfg.copyWith(matchHaptics: v)),
            sub: "If Android's vibration pattern cannot be read, the band "
                 'uses the fallback rhythm below. It plays one buzz per '
                 'pulse, up to three.'),
        SetRow(LucideIcons.waves, C.purple, 'Fallback rhythm',
              enabled: cfg.matchHaptics,
              sub: cfg.matchHaptics ? '' : "Turn on Match Android's vibration first",
              value: rhythm < 0 ? 'Custom' : _rhythms[rhythm].$1,
              chevron: false,
              onTap: () => put(cfg.copyWith(
                  fallbackPattern:
                      _rhythms[(rhythm + 1) % _rhythms.length].$2))),
      ],
      // Not offered while the channel mirrors Android's own vibration, which
      // is what the buzz follows then.
      BuzzPatternRow(
        key: ValueKey('buzz-pattern:channel:$name'),
        sequence: cfg.effectiveSequence,
        enabled: !cfg.matchHaptics && onChannelBuzzPattern != null,
        onTap: () => onChannelBuzzPattern?.call(name),
      ),
      SwitchRow('Buzz during Do Not Disturb', cfg.allowDuringDnd,
          (v) => put(cfg.copyWith(allowDuringDnd: v)),
          sub: name == 'calls'
              ? 'Calls respect Do Not Disturb unless you switch this on. '
                  'Edge never changes your Do Not Disturb setting.'
              : 'Off respects Do Not Disturb. Edge never changes your Do '
                  'Not Disturb setting.'),
      SwitchRow('Buzz in vibrate mode', cfg.includeVibrate,
          (v) => put(cfg.copyWith(includeVibrate: v))),
      SwitchRow('Buzz in silent mode', cfg.includeSilent,
          (v) => put(cfg.copyWith(includeSilent: v))),
      SwitchRow('Phone alert if the band is away', cfg.phoneFallback,
          (v) => put(cfg.copyWith(phoneFallback: v)),
          sub: 'A generic notice on this phone when the band is not '
              'connected. It follows the Do Not Disturb choice above.'),
      SwitchRow(
          'Quiet hours',
          cfg.quietStartMinute != null && cfg.quietEndMinute != null,
          (v) => put(v
              ? cfg.copyWith(quietStartMinute: 22 * 60, quietEndMinute: 7 * 60)
              : cfg.copyWith(clearQuiet: true))),
      // Always drawn; dimmed while quiet hours are off (8K).
      SetRow(LucideIcons.sunset, C.blue, 'Starts',
          enabled: quietOn,
          value: NotificationSettingsView.hhmm(cfg.quietStartMinute ?? 22 * 60),
          chevron: false, onTap: () async {
        final v = await NotificationSettingsView.pickMinute(
            c, cfg.quietStartMinute ?? 22 * 60);
        if (v != null) put(cfg.copyWith(quietStartMinute: v));
      }),
      SetRow(LucideIcons.sunrise, C.yellow, 'Ends',
          enabled: quietOn,
          value: NotificationSettingsView.hhmm(cfg.quietEndMinute ?? 7 * 60),
          chevron: false, onTap: () async {
        final v = await NotificationSettingsView.pickMinute(
            c, cfg.quietEndMinute ?? 7 * 60);
        if (v != null) put(cfg.copyWith(quietEndMinute: v));
      }),
    ];
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.bandNotifNavTitle ?? 'Band notifications',
                sub: l?.bandNotifNavSub ?? 'WHAT MAKES THE BAND BUZZ'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (!supported)
                  StatusCard(
                    l?.bandNotifUnsupportedTitle ?? 'Not available on this phone',
                    l?.bandNotifUnsupportedBody ??
                        'Only Android lets an app read which app posted a '
                        'notification. iOS does not, so Edge cannot relay '
                        'notifications on this phone.',
                    icon: LucideIcons.smartphone,
                  )
                else ...[
                  SettingsAccordion(l?.bandNotifRelayGroup ?? 'Relay', children: [
                    SetRow(LucideIcons.bellRing, C.purple,
                        l?.bandNotifBuzzOnAppNotifs ??
                            'Buzz on app notifications',
                        // What is actually true, and no more. The relay reads
                        // no content and sends nothing anywhere — but it DOES
                        // keep the package names on this phone, because that
                        // list is the only way the picker below can offer you
                        // an app without asking for the permission that
                        // enumerates every app you have installed. "Nothing is
                        // stored" was the wrong claim to make about it.
                        // Wraps to the same line count with On or Off (stable_alert_controls_test).
                        sub: l?.bandNotifBuzzSub ??
                            'The band buzzes when an app below notifies you. Edge never reads or sends what a notification says. It keeps only which app posted, on this phone, to build the list.',
                        value: enabled
                            ? (l?.stateOn ?? 'On')
                            : (l?.stateOff ?? 'Off'),
                        chevron: false,
                        onTap: () => onEnabled?.call(!enabled)),
                  ]),
                  // One setting for the whole relay, not one per channel.
                  SettingsAccordion('Wear', children: [
                    SwitchRow('Only buzz while worn', onlyWhileWorn,
                        onOnlyWhileWorn,
                        sub: _wearSub),
                  ]),
                  // Fixed position: nothing above this card changes height when
                  // the relay is switched on, so it never jumps under a finger.
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.bandNotifOneBuzzTitle ?? 'One buzz per notification',
                    'Updating a notification does not buzz again. A new '
                    'notification does. Ongoing notifications such as '
                    'media players and downloads never buzz. While the '
                    'band is disconnected nothing buzzes, unless you '
                    'turn on the phone alert below.',
                    icon: LucideIcons.waves,
                  ),
                  if (enabled && !granted) ...[
                    const SizedBox(height: S.x4),
                    StatusCard(
                      l?.bandNotifPermissionTitle ??
                          'Android must allow Edge to read notifications',
                      l?.bandNotifPermissionBody ??
                          'Edge uses this permission only to read which app '
                          'posted a notification. The names stay on this phone '
                          'and nothing leaves it.',
                      fix: l?.bandNotifGrantAccess ?? 'Grant notification access',
                      icon: LucideIcons.shieldCheck,
                      onFix: onGrant,
                    ),
                  ],
                  // Three channels, each with its own policy. Per-app choices
                  // exist only on App notifications.
                  SettingsAccordion('App notifications',
                      children: [
                        ..._appRows(c, l),
                        ..._policyRows(c, 'apps'),
                      ]),
                  SettingsAccordion('Alarms & timers',
                      children: _policyRows(c, 'alarms')),
                  SettingsAccordion('Incoming calls',
                      children: _policyRows(c, 'calls')),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// One app. The icon is the identifier a human reads — [appLabel] is only the
/// caption under it, derived from the package name because the app's real
/// label is behind a permission this feature does not ask for.
class _AppRow extends StatelessWidget {
  const _AppRow(this.app,
      {this.enabled = true,
      this.onChanged,
      this.sequence,
      this.onBuzzPattern});
  final RelayApp app;
  final bool enabled;
  final void Function(String pkg, bool on)? onChanged;
  final BuzzSequence? sequence;
  final void Function(String pkg)? onBuzzPattern;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final icon = app.icon;
    // Decoded at the size it is drawn at, same reasoning as _IconChoice in
    // settings.dart: these are launcher masters (Android ships up to 512 px)
    // decoded in full to paint a 32 pt row. WIDTH ONLY — a third-party icon
    // need not be square, and constraining both dimensions would distort it.
    final px = (32 * MediaQuery.devicePixelRatioOf(c)).round();
    final l = AppLocalizations.of(c);
    final row = Pressable(
      onTap: enabled ? () => onChanged?.call(app.package, !app.on) : null,
      semanticLabel: '${appLabel(app.package)}, ${app.on ? (l?.bandNotifBuzzesDescription ?? 'buzzes') : (l?.bandNotifDoesNotBuzzDescription ?? 'does not buzz')}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          ClipRRect(
            borderRadius: R.rSm,
            child: icon != null && icon.isNotEmpty
                ? Image.memory(icon,
                    width: 32,
                    height: 32,
                    cacheWidth: px,
                    gaplessPlayback: true)
                : Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: p.wash(C.purple), borderRadius: R.rSm),
                    child: Icon(LucideIcons.appWindow,
                        size: 16, color: p.on(C.purple)),
                  ),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appLabel(app.package),
                      style: F.body.copyWith(color: p.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(app.package,
                      style: F.over.copyWith(color: p.ink3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ]),
          ),
          const SizedBox(width: S.x2),
          Text(app.on ? (l?.bandNotifBuzzes ?? 'Buzzes') : (l?.stateOff ?? 'Off'),
              style: F.cap.copyWith(
                  color: app.on ? p.on(C.green) : p.ink3,
                  fontWeight: FontWeight.w600)),
          // The app's own rhythm. Present for every app, usable only for one
          // that is switched on.
          if (sequence != null)
            Pressable(
              key: ValueKey('buzz-pattern:app:${app.package}'),
              onTap: enabled && app.on && onBuzzPattern != null
                  ? () => onBuzzPattern!(app.package)
                  : null,
              semanticLabel: 'Buzz pattern, ${buzzSummary(sequence!)}',
              child: Opacity(
                opacity: enabled && app.on && onBuzzPattern != null ? 1 : .4,
                child: Padding(
                  padding: const EdgeInsets.only(left: S.x3),
                  child: Icon(LucideIcons.waves, size: 20, color: p.on(C.purple)),
                ),
              ),
            ),
        ]),
      ),
    );
    return enabled ? row : Opacity(opacity: kDisabledOpacity, child: row);
  }
}
