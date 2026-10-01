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
import '../../notify/notification_relay.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'profile.dart' show SetRow, SettingsAccordion, SwitchRow, settingsGroup;
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
      animation: relay,
      builder: (c, _) => BandNotificationsView(
        supported: relay.supported,
        enabled: relay.enabled,
        granted: relay.permissionGranted,
        apps: [
          for (final p in relay.seenPackages)
            RelayApp(p, icon: relay.iconFor(p), on: relay.isAppEnabled(p)),
        ],
        channels: relay.controller.channels,
        onChannel: relay.controller.putChannel,
        onEnabled: relay.setEnabled,
        onGrant: relay.requestPermission,
        onApp: relay.setAppEnabled,
      ),
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
    this.onGrant,
    this.onApp,
    this.onChannel,
  });

  final bool supported, enabled, granted;
  final List<RelayApp> apps;

  /// Per-channel policy by name (apps, alarms, calls). Absent means defaults.
  final Map<String, ChannelConfig> channels;
  final void Function(String channel, ChannelConfig next)? onChannel;
  final ValueChanged<bool>? onEnabled;
  final VoidCallback? onGrant;
  final void Function(String pkg, bool on)? onApp;

  /// How many apps are actually armed — the one number that says whether the
  /// feature will do anything at all.
  int get _armed => apps.where((a) => a.on).length;

  List<Widget> _appRows(BuildContext c, AppLocalizations? l) => [
    SetRow(LucideIcons.listChecks, C.teal,
        l?.bandNotifAppsArmed ?? 'Apps armed',
        value: '$_armed', chevron: false),
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
                  'Apps appear here the first time each one notifies you '
                      'while the relay is on. Nothing is missed in the '
                      'meantime — the first ping is what puts an app on this '
                      'list, and the second can buzz.',
              style: F.over.copyWith(color: P.of(c).ink3)),
        ]),
      )
    else
      for (final a in apps) _AppRow(a, onChanged: onApp),
  ];

  /// Fallback rhythms for alarm matching, tapped through in place.
  static const _rhythms = [
    ('One short', [0, 250]),
    ('Two long', [0, 400, 100, 400]),
    ('Three short', [0, 150, 100, 150, 100, 150]),
  ];

  /// The policy every channel carries once: Do Not Disturb, vibrate, silent,
  /// worn, phone alert and quiet hours.
  List<Widget> _policyRows(BuildContext c, String name) {
    final cfg = channels[name] ?? ChannelConfig.forChannel(name);
    void put(ChannelConfig next) => onChannel?.call(name, next);
    final rhythm = _rhythms.indexWhere(
        (r) => r.$2.join(',') == cfg.fallbackPattern.join(','));
    return [
      SwitchRow('Relay to the band', cfg.enabled,
          (v) => put(cfg.copyWith(enabled: v))),
      if (name == 'alarms') ...[
        SwitchRow("Match Android's vibration", cfg.matchHaptics,
            (v) => put(cfg.copyWith(matchHaptics: v)),
            sub: "When Android's own pattern cannot be read, the fallback "
                'rhythm below is used. The band plays one buzz per pulse, up '
                'to three — not the exact rhythm.'),
        if (cfg.matchHaptics)
          SetRow(LucideIcons.waves, C.purple, 'Fallback rhythm',
              value: rhythm < 0 ? 'Custom' : _rhythms[rhythm].$1,
              chevron: false,
              onTap: () => put(cfg.copyWith(
                  fallbackPattern:
                      _rhythms[(rhythm + 1) % _rhythms.length].$2))),
      ],
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
      SwitchRow('Only while worn', cfg.onlyWhileWorn,
          (v) => put(cfg.copyWith(onlyWhileWorn: v)),
          sub: 'If wear cannot be confirmed, nothing buzzes.'),
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
      if (cfg.quietStartMinute != null && cfg.quietEndMinute != null) ...[
        SetRow(LucideIcons.sunset, C.blue, 'Starts',
            value: NotificationSettingsView.hhmm(cfg.quietStartMinute!),
            chevron: false, onTap: () async {
          final v = await NotificationSettingsView.pickMinute(
              c, cfg.quietStartMinute!);
          if (v != null) put(cfg.copyWith(quietStartMinute: v));
        }),
        SetRow(LucideIcons.sunrise, C.yellow, 'Ends',
            value: NotificationSettingsView.hhmm(cfg.quietEndMinute!),
            chevron: false, onTap: () async {
          final v = await NotificationSettingsView.pickMinute(
              c, cfg.quietEndMinute!);
          if (v != null) put(cfg.copyWith(quietEndMinute: v));
        }),
      ],
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
                sub: l?.bandNotifNavSub ?? 'WHAT MAKES THE STRAP BUZZ'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (!supported)
                  StatusCard(
                    l?.bandNotifUnsupportedTitle ?? 'This phone cannot do it',
                    l?.bandNotifUnsupportedBody ??
                        'Reading which app posted a notification is an Android '
                            'capability. iOS gives no app that access, including '
                            'this one.',
                    icon: LucideIcons.smartphone,
                  )
                else ...[
                  settingsGroup(c, l?.bandNotifRelayGroup ?? 'Relay', [
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
                        sub: l?.bandNotifBuzzSub ??
                            'The strap buzzes when one of the apps below '
                                'notifies you. What a notification says is never '
                                'read or sent — only which app posted, kept on '
                                'this phone to build the list',
                        value: enabled
                            ? (l?.stateOn ?? 'On')
                            : (l?.stateOff ?? 'Off'),
                        chevron: false,
                        onTap: () => onEnabled?.call(!enabled)),
                  ]),
                  // Fixed position: nothing above this card changes height when
                  // the relay is switched on, so it never jumps under a finger.
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.bandNotifOneBuzzTitle ?? 'One buzz, not a stream',
                    'An update to a notification never buzzes again; a new '
                        'one does. Ongoing notifications (media players, '
                        'downloads) never buzz, and nothing buzzes while the '
                        'band is disconnected unless you choose the phone '
                        'alert below.',
                    icon: LucideIcons.waves,
                  ),
                  if (enabled && !granted) ...[
                    const SizedBox(height: S.x4),
                    StatusCard(
                      l?.bandNotifPermissionTitle ??
                          'Android needs to let us see notifications',
                      l?.bandNotifPermissionBody ??
                          'The permission says which app posted, and that is all '
                              'this uses it for. The names stay on this phone and '
                              'nothing leaves it.',
                      fix: l?.bandNotifGrantAccess ?? 'Grant notification access',
                      icon: LucideIcons.shieldCheck,
                      onFix: onGrant,
                    ),
                  ],
                  // Three channels, each with its own policy. Per-app choices
                  // exist only on App notifications.
                  SettingsAccordion('App notifications',
                      initiallyExpanded: true,
                      children: [
                        if (enabled && granted) ..._appRows(c, l),
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
  const _AppRow(this.app, {this.onChanged});
  final RelayApp app;
  final void Function(String pkg, bool on)? onChanged;

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
    return Pressable(
      onTap: () => onChanged?.call(app.package, !app.on),
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
        ]),
      ),
    );
  }
}
