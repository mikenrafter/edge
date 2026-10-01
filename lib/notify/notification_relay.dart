// notification_relay.dart — relay selected phone notifications to the strap as a
// haptic buzz. ANDROID ONLY: it rides an app-owned NotificationListenerService
// (OpenStrapNotificationListener.kt). iOS has no API to observe other apps'
// notifications, so on iOS this whole feature is inert and the UI never shows it.
//
// PRIVACY. Dart receives routing metadata only — category, package, a hash of
// the system key, post/remove time, filter/ringer state, ongoing/group flags,
// channel importance and a readable vibration pattern. Never a title or body.
//
// Three independent channels (apps, alarms, calls), each with its own policy.
// [RelayController] is the pure decision engine; [NotificationRelay] is the
// persisted ChangeNotifier that owns the platform bridge and feeds it. Delivery
// goes through [AlertDispatcher], so staleness, band availability and the
// optional phone fallback are decided in the one shared place.

import 'dart:async';
import 'dart:convert';
import 'alert_dispatcher.dart';
import 'alert_rule.dart';
import 'notification_prefs.dart';
import 'notification_center.dart';
import 'notification_event.dart';
import '../data/day_label.dart';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The relay's channels. `category=alarm` covers alarms and timers;
/// `category=call` covers system and VoIP calls; everything else is an app.
const relayChannels = ['apps', 'alarms', 'calls'];

String relayChannelOf(Object? category) => switch (category) {
  'alarm' => 'alarms',
  'call' => 'calls',
  _ => 'apps',
};

/// One channel's policy. Defaults: apps relay when the feature is on; alarms and
/// calls are opt-in; Do Not Disturb, vibrate and silent are all respected.
class ChannelConfig {
  const ChannelConfig({
    this.enabled = false,
    this.matchHaptics = false,
    this.fallbackPattern = const [0, 400, 100, 400],
    this.quietStartMinute,
    this.quietEndMinute,
    this.allowDuringDnd = false,
    this.includeVibrate = true,
    this.includeSilent = false,
    this.onlyWhileWorn = false,
    this.phoneFallback = false,
  });
  /// Apps relay once the feature is on; alarms and calls are opt-in.
  factory ChannelConfig.forChannel(String name) =>
      ChannelConfig(enabled: name == 'apps');

  final bool enabled, matchHaptics, allowDuringDnd, includeVibrate;
  final bool includeSilent, onlyWhileWorn, phoneFallback;
  final List<int> fallbackPattern;
  final int? quietStartMinute, quietEndMinute;

  ChannelConfig copyWith({
    bool? enabled,
    bool? matchHaptics,
    List<int>? fallbackPattern,
    int? quietStartMinute,
    int? quietEndMinute,
    bool clearQuiet = false,
    bool? allowDuringDnd,
    bool? includeVibrate,
    bool? includeSilent,
    bool? onlyWhileWorn,
    bool? phoneFallback,
  }) => ChannelConfig(
    enabled: enabled ?? this.enabled,
    matchHaptics: matchHaptics ?? this.matchHaptics,
    fallbackPattern: fallbackPattern ?? this.fallbackPattern,
    quietStartMinute: clearQuiet
        ? null
        : quietStartMinute ?? this.quietStartMinute,
    quietEndMinute: clearQuiet ? null : quietEndMinute ?? this.quietEndMinute,
    allowDuringDnd: allowDuringDnd ?? this.allowDuringDnd,
    includeVibrate: includeVibrate ?? this.includeVibrate,
    includeSilent: includeSilent ?? this.includeSilent,
    onlyWhileWorn: onlyWhileWorn ?? this.onlyWhileWorn,
    phoneFallback: phoneFallback ?? this.phoneFallback,
  );

  /// The per-channel half of the decision policy. The environment half (DND,
  /// ringer, connectivity, wear) comes from the policy source and wins on overlap.
  Map<String, Object?> get policy => {
    'respectDnd': true,
    'allowDuringDnd': allowDuringDnd,
    'includeVibrate': includeVibrate,
    'includeSilent': includeSilent,
    'onlyWhileWorn': onlyWhileWorn,
    'fallback': phoneFallback ? 'phoneIfBandUnavailable' : 'none',
  };

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'matchHaptics': matchHaptics,
    'fallbackPattern': fallbackPattern,
    'quietStartMinute': quietStartMinute,
    'quietEndMinute': quietEndMinute,
    'allowDuringDnd': allowDuringDnd,
    'includeVibrate': includeVibrate,
    'includeSilent': includeSilent,
    'onlyWhileWorn': onlyWhileWorn,
    'phoneFallback': phoneFallback,
  };

  factory ChannelConfig.fromJson(Map<String, Object?> j, ChannelConfig d) =>
      ChannelConfig(
        enabled: j['enabled'] as bool? ?? d.enabled,
        matchHaptics: j['matchHaptics'] as bool? ?? d.matchHaptics,
        fallbackPattern:
            (j['fallbackPattern'] as List?)?.cast<int>() ?? d.fallbackPattern,
        quietStartMinute: j['quietStartMinute'] as int?,
        quietEndMinute: j['quietEndMinute'] as int?,
        allowDuringDnd: j['allowDuringDnd'] as bool? ?? d.allowDuringDnd,
        includeVibrate: j['includeVibrate'] as bool? ?? d.includeVibrate,
        includeSilent: j['includeSilent'] as bool? ?? d.includeSilent,
        onlyWhileWorn: j['onlyWhileWorn'] as bool? ?? d.onlyWhileWorn,
        phoneFallback: j['phoneFallback'] as bool? ?? d.phoneFallback,
      );
}

class RelayResult {
  const RelayResult({
    this.targets = const [],
    this.suppression,
    this.usedFallbackPattern = false,
  });
  final List<String> targets;
  final String? suppression;
  final bool usedFallbackPattern;
}

/// Decides, per posted notification, whether the band (or the opted-in phone
/// fallback) alerts. No platform access: everything arrives as metadata.
///
/// Policy keys read from [policy] (environment wins over the channel's own):
/// enabled, dnd, respectDnd, allowDuringDnd, ringer (normal|vibrate|silent),
/// includeVibrate, includeSilent, connected, fallback, worn (worn|notWorn|
/// unknown), onlyWhileWorn, packages, staleAfterMs, minuteOfDay.
class RelayController {
  RelayController({
    required this.dispatcher,
    required this.buzz,
    required this.phone,
    required this.policy,
    required this.nowMs,
    this.onChanged,
  });
  final AlertDispatcher dispatcher;
  final Future<bool> Function(List<int> pattern) buzz;
  final Future<bool> Function() phone;
  final Map<String, Object?> Function(Map<String, Object?> metadata) policy;
  final int Function() nowMs;
  final VoidCallback? onChanged;

  final Map<String, ChannelConfig> channels = {
    for (final c in relayChannels) c: ChannelConfig.forChannel(c),
  };

  // Stable-key lifetime: a key is "live" from its first post until its removal,
  // so updates never re-buzz and a reposted notification does.
  final Set<String> _live = {};
  final Set<String> _inFlight = {};
  int _seq = 0;
  bool _listening = true;

  bool get listening => _listening;
  bool get busy => _inFlight.isNotEmpty;

  void setChannel(
    String name, {
    bool? enabled,
    bool? matchHaptics,
    List<int>? fallbackPattern,
    int? quietStartMinute,
    int? quietEndMinute,
    bool clearQuiet = false,
    bool? allowDuringDnd,
    bool? includeVibrate,
    bool? includeSilent,
    bool? onlyWhileWorn,
    bool? phoneFallback,
  }) => putChannel(
    name,
    channels[name]!.copyWith(
      enabled: enabled,
      matchHaptics: matchHaptics,
      fallbackPattern: fallbackPattern,
      quietStartMinute: quietStartMinute,
      quietEndMinute: quietEndMinute,
      clearQuiet: clearQuiet,
      allowDuringDnd: allowDuringDnd,
      includeVibrate: includeVibrate,
      includeSilent: includeSilent,
      onlyWhileWorn: onlyWhileWorn,
      phoneFallback: phoneFallback,
    ),
  );

  void putChannel(String name, ChannelConfig cfg) {
    channels[name] = cfg;
    onChanged?.call();
  }

  Future<RelayResult> handleMetadata(Map<String, Object?> m) async {
    if (!_listening) return const RelayResult(suppression: 'notListening');
    final key = '${m['keyHash']}';
    if (m['kind'] == 'remove') {
      _live.remove(key);
      return const RelayResult(suppression: 'removed');
    }
    final channel = relayChannelOf(m['category']);
    final cfg = channels[channel]!;
    final env = {...cfg.policy, ...policy(m)};
    if (env['enabled'] != true || !cfg.enabled) {
      return const RelayResult(suppression: 'disabled');
    }
    if (m['groupSummary'] == true) {
      return const RelayResult(suppression: 'groupSummary');
    }
    // Only app posts are filtered by ongoing flag and the per-app allow-list.
    // Alarms and calls are chosen by category, not by package.
    if (channel == 'apps' &&
        (m['ongoing'] == true ||
            !((env['packages'] as List?)?.contains(m['package']) ?? false))) {
      return const RelayResult(suppression: 'notSelected');
    }
    // Claimed synchronously, before any await: concurrent posts of one key
    // reach here one at a time.
    if (!_live.add(key)) return const RelayResult(suppression: 'duplicate');
    _inFlight.add(key);
    try {
      if (env['dnd'] == true &&
          env['respectDnd'] != false &&
          env['allowDuringDnd'] != true) {
        return const RelayResult(suppression: 'dnd');
      }
      final ringer = env['ringer'];
      if ((ringer == 'vibrate' && env['includeVibrate'] != true) ||
          (ringer == 'silent' && env['includeSilent'] != true)) {
        return const RelayResult(suppression: 'ringer');
      }
      // Unknown wear abstains: only an explicit "worn" lets a buzz through.
      if (env['onlyWhileWorn'] == true && env['worn'] != 'worn') {
        return const RelayResult(suppression: 'notWorn');
      }
      final start = cfg.quietStartMinute, end = cfg.quietEndMinute;
      if (start != null && end != null) {
        final now = DateTime.fromMillisecondsSinceEpoch(nowMs());
        final minute = env['minuteOfDay'] as int? ?? now.hour * 60 + now.minute;
        if (NotificationPrefs(
          quietEnabled: true,
          quietStartMin: start,
          quietEndMin: end,
        ).inQuietHours(minute)) {
          return const RelayResult(suppression: 'quietHours');
        }
      }
      final readable = _readable(m['hapticPattern']);
      final usedFallback = cfg.matchHaptics && readable == null;
      final pattern = !cfg.matchHaptics
          ? const [0, 250]
          : readable ?? cfg.fallbackPattern;
      final postMs = m['postTimeMs'] as int? ?? nowMs();
      final outcome = await dispatcher.dispatch(
        AlertRule(
          id: 'relay',
          kind: 'relay',
          destinations: AlertRule.band,
          executionMode: AlertExecutionMode.phoneLive,
          fallback: env['fallback'] == 'phoneIfBandUnavailable'
              ? AlertFallback.phoneIfBandUnavailable
              : AlertFallback.none,
          staleAfter: Duration(
            milliseconds: env['staleAfterMs'] as int? ?? 30000,
          ),
          channelPolicyId: 'relay',
        ),
        // The sequence keeps a reposted key (same hash, same post time after a
        // removal) from colliding with its own earlier delivery claim.
        // ponytail: a restart can re-deliver an entry still posted within the
        // stale window; widen with a persisted high-water mark if that bites.
        eventId: '$channel:$key:$postMs:${_seq++}',
        sourceTime: DateTime.fromMillisecondsSinceEpoch(postMs),
        historical: false,
        phoneTransport: phone,
        bandTransport: () => buzz(pattern),
      );
      return RelayResult(
        targets: outcome.targets,
        suppression: outcome.suppressionReason,
        usedFallbackPattern: usedFallback && outcome.targets.contains('band'),
      );
    } finally {
      _inFlight.remove(key);
    }
  }

  List<int>? _readable(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.any((e) => e is! int)) return null;
    return raw.cast<int>();
  }

  /// The system unbound the listener. Live keys are kept so a reconnect does
  /// not replay notifications that already alerted.
  Future<void> listenerDisconnected() async {
    _listening = false;
    _inFlight.clear();
  }

  /// Bound again. [active] is what the system still shows: keys removed while
  /// we were away are forgotten, known keys stay quiet, and anything older than
  /// the stale window is refused by the dispatcher rather than replayed.
  Future<void> listenerConnected(List<Object?> active) async {
    _listening = true;
    final entries = [
      for (final e in active) Map<String, Object?>.from(e as Map),
    ];
    _live.retainAll({for (final m in entries) '${m['keyHash']}'});
    for (final m in entries) {
      await handleMetadata({...m, 'kind': 'post'});
    }
  }

  /// Service destroyed or access revoked: drop every latch. Channel policy is
  /// kept, so the next [listenerConnected] restores it.
  Future<void> stop(String reason) async {
    _listening = false;
    _live.clear();
    _inFlight.clear();
  }

  void dispose() {
    _listening = false;
    _live.clear();
    _inFlight.clear();
  }
}

class NotificationRelay extends ChangeNotifier with WidgetsBindingObserver {
  NotificationRelay({
    required this.buzz,
    required this.isConnected,
    AlertDispatcher? dispatcher,
    this.worn,
  }) : dispatcher =
           dispatcher ??
           AlertDispatcher(
             phone: () async => false,
             band: () async {
               await buzz();
               return true;
             },
             isConnected: isConnected,
           );
  final AlertDispatcher dispatcher;

  /// "worn" / "notWorn" / "unknown". Null means no wear source: unknown, so an
  /// only-while-worn channel abstains rather than guessing.
  final String Function()? worn;

  // The app-owned listener bridge (OpenStrapNotificationListener.kt).
  static const MethodChannel _native = MethodChannel(
    'openstrap/notification_relay',
  );
  static const Duration _healEvery = Duration(seconds: 120);
  Timer? _healTimer;

  /// Fire the strap haptic. Wired by AppState to `engine.buzz()`. Best-effort.
  final Future<void> Function() buzz;

  /// Whether the band is currently connected (no point buzzing nothing).
  final bool Function() isConnected;

  static const _kEnabled = 'notif_relay_enabled';
  static const _kPackages = 'notif_relay_packages';
  static const _kSeen = 'notif_relay_seen';
  static const _kChannels = 'notif_relay_channels';

  /// How many apps the "seen" list remembers. A phone posts from a long tail
  /// of packages over a week; past this the list stops being a list you can
  /// read.
  static const int maxSeen = 60;

  /// Only Android can observe other apps' notifications. Everything below is a
  /// no-op when this is false, and the UI hides the feature entirely.
  bool get supported => Platform.isAndroid;

  bool _enabled = false;
  bool get enabled => _enabled;

  bool _granted = false;
  bool get permissionGranted => _granted;

  /// Packages that have actually posted a notification while the listener was
  /// running, most recent first. This is what the picker offers.
  ///
  /// The alternative — enumerating installed apps — needs QUERY_ALL_PACKAGES,
  /// which was deliberately removed from the manifest with `tools:node=remove`
  /// as the most policy-expensive permission there is. It is also the worse
  /// list: two hundred packages to scroll, against the dozen that actually
  /// interrupt you.
  final List<String> _seen = [];

  /// Per-package icon. The native bridge sends none (icons are not routing
  /// metadata), so the picker shows its placeholder; kept for the picker API.
  final Map<String, Uint8List> _icons = {};

  List<String> get seenPackages => List.unmodifiable(_seen);
  Uint8List? iconFor(String pkg) => _icons[pkg];

  final Set<String> _packages = {};
  Set<String> get packages => _packages;
  bool isAppEnabled(String pkg) => _packages.contains(pkg);
  int get appCount => _packages.length;

  /// True only when the relay can actually alert: on, permitted, on Android.
  /// Alarms and calls need no app selected, so the app list does not gate it.
  bool get active => supported && _enabled && _granted;

  late final RelayController controller = RelayController(
    dispatcher: dispatcher,
    buzz: _playPattern,
    phone: _phoneFallback,
    policy: _policy,
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
    onChanged: _channelsChanged,
  );

  /// Tests only: the same production controller with injected sinks and a
  /// fixed policy, an in-memory delivery ledger and a fixed clock.
  @visibleForTesting
  RelayController debugController({
    required Map<String, Object?> policy,
    required Future<bool> Function(List<int>) buzz,
    required Future<bool> Function() phone,
    required int Function() nowMs,
  }) {
    var connected = true;
    return RelayController(
      // isConnected is read synchronously at the top of dispatch, right after
      // this closure's policy call, so the shared variable cannot interleave.
      dispatcher: AlertDispatcher(
        phone: phone,
        band: () async => false,
        isConnected: () => connected,
        now: () => DateTime.fromMillisecondsSinceEpoch(nowMs()),
        ledger: MemoryAlertDeliveryLedger(),
      ),
      buzz: buzz,
      phone: phone,
      policy: (_) {
        connected = policy['connected'] == true;
        return policy;
      },
      nowMs: nowMs,
    );
  }

  Map<String, Object?> _policy(Map<String, Object?> m) => {
    'enabled': _enabled && _granted,
    // INTERRUPTION_FILTER_ALL = 1; unknown (0) is not treated as DND.
    'dnd': const {2, 3, 4}.contains(m['interruptionFilter']),
    'ringer': switch (m['ringerMode']) {
      0 => 'silent',
      1 => 'vibrate',
      2 => 'normal',
      _ => 'unknown',
    },
    'connected': isConnected(),
    'worn': worn?.call() ?? 'unknown',
    'packages': _packages.toList(),
  };

  /// A phone alert that names neither the app nor the content.
  Future<bool> _phoneFallback() {
    final now = DateTime.now();
    return NotificationCenter.instance.emit(
      NotificationEvent(
        dedupeKey: 'relay:${now.microsecondsSinceEpoch}',
        category: NotifCategory.reminders,
        title: 'Relayed alert',
        body: 'An alert you chose to relay arrived while the band was disconnected.',
        date: dayLabelOf(now),
      ),
      sourceTime: now,
      ruleId: 'relay',
      phoneOnly: true,
    );
  }

  /// The band takes a pattern id, not a waveform, so Android's rhythm is
  /// approximated by its pulse count (odd entries are the "on" segments).
  // ponytail: pulse count only, capped at 3; exact rhythm needs a band opcode.
  Future<bool> _playPattern(List<int> pattern) async {
    final pulses = [
      for (var i = 1; i < pattern.length; i += 2)
        if (pattern[i] > 0) i,
    ].length.clamp(1, 3);
    for (var i = 0; i < pulses; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 350));
      await buzz();
    }
    return true;
  }

  void _channelsChanged() {
    SharedPreferences.getInstance()
        .then(
          (p) => p.setString(
            _kChannels,
            jsonEncode({
              for (final e in controller.channels.entries)
                e.key: e.value.toJson(),
            }),
          ),
        )
        .catchError((_) => false);
    notifyListeners();
  }

  /// Load saved state, refresh permission, and start listening if active. Call
  /// once at startup. No-op on iOS.
  Future<void> bootstrap() async {
    if (!supported) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _packages
      ..clear()
      ..addAll(prefs.getStringList(_kPackages) ?? const []);
    _seen
      ..clear()
      ..addAll(prefs.getStringList(_kSeen) ?? const []);
    final stored = prefs.getString(_kChannels);
    if (stored != null) {
      final saved = Map<String, Object?>.from(jsonDecode(stored) as Map);
      for (final c in relayChannels) {
        final j = saved[c];
        if (j is Map) {
          controller.channels[c] = ChannelConfig.fromJson(
            Map<String, Object?>.from(j),
            controller.channels[c]!,
          );
        }
      }
    }
    // An app already on the allow-list belongs in the picker whether or not it
    // has posted since launch — otherwise turning the feature on and reopening
    // the screen shows an empty list with your choices invisibly still active.
    for (final p in _packages) {
      if (!_seen.contains(p)) _seen.add(p);
    }
    _native.setMethodCallHandler(_onNative);
    WidgetsBinding.instance.addObserver(this);
    await refreshPermission();
    _resync();
    notifyListeners();
  }

  // Native -> Dart. Errors never propagate back into the system callback.
  Future<void> _onNative(MethodCall call) async {
    try {
      final a = call.arguments;
      switch (call.method) {
        case 'metadata':
          final m = Map<String, Object?>.from(a as Map);
          // BEFORE the allow-list check: an app you have not chosen yet is
          // exactly the one the picker needs to be able to offer you.
          final pkg = m['package'];
          if (m['kind'] == 'post' &&
              pkg is String &&
              pkg.isNotEmpty &&
              relayChannelOf(m['category']) == 'apps') {
            noteSeen(pkg, null);
          }
          await controller.handleMetadata(m);
        case 'connected':
          await controller.listenerConnected(a as List);
        case 'disconnected':
          await controller.listenerDisconnected();
        case 'destroyed':
          await controller.stop('destroyed');
      }
    } catch (_) {
      /* a bad event is dropped, never thrown at the platform */
    }
  }

  // The OS can unbind the listener while we're backgrounded. On every
  // foreground return, re-check the grant and re-arm.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && supported) {
      refreshPermission().then((_) {
        _resync();
        _heal();
      });
    }
  }

  /// Re-query the OS "Notification access" grant (it can change while we're
  /// backgrounded — user revokes it in Settings). Returns the current value.
  /// A revocation clears every listener latch.
  Future<bool> refreshPermission() async {
    if (!supported) return false;
    final was = _granted;
    try {
      _granted = await _native.invokeMethod<bool>('isPermissionGranted') ?? false;
    } catch (_) {
      _granted = false;
    }
    if (was && !_granted) await controller.stop('permissionRevoked');
    notifyListeners();
    return _granted;
  }

  /// Open the system Notification-access settings page and return once the user
  /// comes back. We re-read the real grant rather than trusting the return value.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      await _native.invokeMethod('requestPermission');
    } catch (_) {
      /* user may just back out */
    }
    final ok = await refreshPermission();
    _resync();
    return ok;
  }

  Future<void> setEnabled(bool on) async {
    if (!supported || on == _enabled) return;
    _enabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, on);
    final alerts = await NotificationPrefs.load();
    final rule = alerts.alertRule('relay');
    await alerts
        .withAlertRule(
          rule
              .copyWith(
                enabled: on,
                destinations: on
                    ? (rule.destinations == 0 ? 2 : rule.destinations)
                    : 0,
              )
              .toJson(),
        )
        .save();
    _resync();
    notifyListeners();
  }

  Future<void> setAppEnabled(String pkg, bool on) async {
    if (!supported) return;
    if (on) {
      if (!_packages.add(pkg)) return;
    } else {
      if (!_packages.remove(pkg)) return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPackages, _packages.toList());
    notifyListeners();
  }

  // Tell the platform whether metadata should flow at all, and when arming pull
  // what is currently posted so the controller restores state without replay.
  // The heal timer only runs while armed.
  void _resync() {
    final shouldListen = active;
    _native.invokeMethod('setArmed', shouldListen).then((_) async {
      if (shouldListen) {
        final list = await _native.invokeMethod<List<Object?>>('activeMetadata');
        await controller.listenerConnected(list ?? const []);
      } else {
        await controller.stop('disarmed');
      }
    }).catchError((_) {});
    if (shouldListen) {
      _healTimer ??= Timer.periodic(_healEvery, (_) => _heal());
    } else {
      _healTimer?.cancel();
      _healTimer = null;
    }
  }

  // Ask the native side whether the listener is still bound; if not, request a
  // rebind. Best-effort — the system also rebinds on its own schedule.
  Future<void> _heal() async {
    if (!active) return;
    try {
      if (!(await _native.invokeMethod<bool>('isConnected') ?? true)) {
        await _native.invokeMethod('rebind');
      }
    } catch (_) {
      /* handler absent — ignore */
    }
  }

  /// Remember that [pkg] notifies, so the picker has something to offer.
  ///
  /// Persisted only when the package is NEW: the in-memory order changes on
  /// every ping and a SharedPreferences write per notification would be a
  /// disk write per notification.
  @visibleForTesting
  void noteSeen(String pkg, Uint8List? icon) {
    if (icon != null && icon.isNotEmpty) _icons[pkg] = icon;
    final known = _seen.remove(pkg);
    _seen.insert(0, pkg);
    if (_seen.length > maxSeen) {
      // Oldest first, but an ARMED app is never evicted. The picker is built
      // from this list, so dropping one you turned ON leaves it buzzing the
      // strap with no row to turn it off from — a thing that keeps acting on
      // you with no way to stop it. The bound survives: the overflow is at most
      // the apps you chose yourself.
      for (var i = _seen.length - 1; i >= 0 && _seen.length > maxSeen; i--) {
        if (!_packages.contains(_seen[i])) _seen.removeAt(i);
      }
      // The icons go with them. `_seen` is bounded, `_icons` was not — an
      // evicted package left its bitmap resident for the life of the process,
      // and on a phone with a lot of chatty apps that is the picker's whole
      // icon set held for a list it is no longer on.
      // ponytail: O(n) scan over 60 entries, only on eviction.
      _icons.removeWhere((k, _) => !_seen.contains(k));
    }
    if (!known) {
      SharedPreferences.getInstance()
          .then((p) => p.setStringList(_kSeen, _seen))
          .catchError((_) => false);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healTimer?.cancel();
    controller.dispose();
    super.dispose();
  }
}

/// A readable name for [pkg], from the package name alone.
///
/// An app's own label lives behind `getApplicationLabel`, which needs the
/// package-visibility permission this feature deliberately does not have — so
/// the ICON beside it (taken off the notification itself) is the identifier a
/// human actually reads, and this is the caption under it.
///
/// The last meaningful segment, capitalised: `com.whatsapp` → "Whatsapp",
/// `org.telegram.messenger` → "Messenger", `com.foo.android` → "Foo". Segments
/// that name a platform or a build rather than a product are stepped over,
/// because "Android" under every second icon is not a name.
String appLabel(String pkg) {
  const generic = {
    'android',
    'app',
    'apps',
    'client',
    'mobile',
    'main',
    'ui',
    'free',
    'pro',
    'lite',
    'beta',
    'release',
  };
  final parts = [
    for (final p in pkg.split('.'))
      if (p.isNotEmpty) p,
  ];
  if (parts.isEmpty) return pkg;
  var i = parts.length - 1;
  while (i > 0 && generic.contains(parts[i].toLowerCase())) {
    i--;
  }
  final w = parts[i];
  return w[0].toUpperCase() + w.substring(1);
}
