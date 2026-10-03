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
import 'buzz_sequence.dart';
import 'notification_prefs.dart';
import 'notification_center.dart';
import 'notification_event.dart';
import '../data/day_label.dart';
import '../haptics/band_queue.dart' show BandJobToken;
import '../state/feature_flags.dart';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The relay's channels. `category=alarm` covers alarms and timers;
/// `category=call` covers system and VoIP calls; everything else is an app.
const relayChannels = ['apps', 'alarms', 'calls'];

/// What the band itself reports about being worn: `DeviceState.wristOn` as the
/// policy's vocabulary. A band that has said nothing is unknown, never worn.
String wearReportOf(bool? wristOn) => switch (wristOn) {
  true => 'worn',
  false => 'notWorn',
  null => 'unknown',
};

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
    this.overrideQuietHours = false,
    this.allowDuringDnd = false,
    this.includeVibrate = true,
    this.includeSilent = false,
    this.phoneFallback = false,
    this.buzzSequence,
    this.appSequences = const {},
  });
  /// Apps relay once the feature is on; alarms and calls are opt-in.
  factory ChannelConfig.forChannel(String name) =>
      ChannelConfig(enabled: name == 'apps');

  final bool enabled, matchHaptics, allowDuringDnd, includeVibrate;
  final bool includeSilent, phoneFallback;
  final List<int> fallbackPattern;
  final int? quietStartMinute, quietEndMinute;

  /// True: this channel's own Starts and Ends decide its quiet hours (both
  /// null means none). False: it follows the global quiet hours from Alerts,
  /// and any stored times are kept but not used.
  final bool overrideQuietHours;

  /// The channel's own buzz rhythm; null takes the relay rule's default.
  final BuzzSequence? buzzSequence;

  /// Per-app rhythms (package -> sequence). An app without one uses the
  /// channel's. Only the apps channel reads this.
  final Map<String, BuzzSequence> appSequences;

  BuzzSequence get effectiveSequence =>
      buzzSequence ??
      BuzzSequence.defaultFor(NotificationPrefs.alertRuleOrder.indexOf('relay'));

  BuzzSequence sequenceForApp(String pkg) =>
      appSequences[pkg] ?? effectiveSequence;

  ChannelConfig copyWith({
    bool? enabled,
    bool? matchHaptics,
    List<int>? fallbackPattern,
    int? quietStartMinute,
    int? quietEndMinute,
    bool clearQuiet = false,
    bool? overrideQuietHours,
    bool? allowDuringDnd,
    bool? includeVibrate,
    bool? includeSilent,
    bool? phoneFallback,
    BuzzSequence? buzzSequence,
    bool clearBuzzSequence = false,
    Map<String, BuzzSequence>? appSequences,
  }) => ChannelConfig(
    enabled: enabled ?? this.enabled,
    matchHaptics: matchHaptics ?? this.matchHaptics,
    fallbackPattern: fallbackPattern ?? this.fallbackPattern,
    quietStartMinute: clearQuiet
        ? null
        : quietStartMinute ?? this.quietStartMinute,
    quietEndMinute: clearQuiet ? null : quietEndMinute ?? this.quietEndMinute,
    overrideQuietHours: overrideQuietHours ?? this.overrideQuietHours,
    allowDuringDnd: allowDuringDnd ?? this.allowDuringDnd,
    includeVibrate: includeVibrate ?? this.includeVibrate,
    includeSilent: includeSilent ?? this.includeSilent,
    phoneFallback: phoneFallback ?? this.phoneFallback,
    buzzSequence: clearBuzzSequence
        ? null
        : buzzSequence ?? this.buzzSequence,
    appSequences: appSequences ?? this.appSequences,
  );

  /// The per-channel half of the decision policy. The environment half (DND,
  /// ringer, connectivity, wear) comes from the policy source and wins on overlap.
  Map<String, Object?> get policy => {
    'respectDnd': true,
    'allowDuringDnd': allowDuringDnd,
    'includeVibrate': includeVibrate,
    'includeSilent': includeSilent,
    'fallback': phoneFallback ? 'phoneIfBandUnavailable' : 'none',
  };

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'matchHaptics': matchHaptics,
    'fallbackPattern': fallbackPattern,
    'quietStartMinute': quietStartMinute,
    'quietEndMinute': quietEndMinute,
    'overrideQuietHours': overrideQuietHours,
    'allowDuringDnd': allowDuringDnd,
    'includeVibrate': includeVibrate,
    'includeSilent': includeSilent,
    'phoneFallback': phoneFallback,
    if (buzzSequence != null) 'buzzSequence': buzzSequence!.toJson(),
    if (appSequences.isNotEmpty)
      'appSequences': {
        for (final e in appSequences.entries) e.key: e.value.toJson(),
      },
  };

  factory ChannelConfig.fromJson(Map<String, Object?> j, ChannelConfig d) =>
      ChannelConfig(
        enabled: j['enabled'] as bool? ?? d.enabled,
        matchHaptics: j['matchHaptics'] as bool? ?? d.matchHaptics,
        fallbackPattern:
            (j['fallbackPattern'] as List?)?.cast<int>() ?? d.fallbackPattern,
        quietStartMinute: j['quietStartMinute'] as int?,
        quietEndMinute: j['quietEndMinute'] as int?,
        // Configs saved before the override existed: a channel that had its own
        // window keeps it (override on); one without follows the global hours.
        overrideQuietHours:
            j['overrideQuietHours'] as bool? ??
            (j['quietStartMinute'] is int && j['quietEndMinute'] is int),
        allowDuringDnd: j['allowDuringDnd'] as bool? ?? d.allowDuringDnd,
        includeVibrate: j['includeVibrate'] as bool? ?? d.includeVibrate,
        includeSilent: j['includeSilent'] as bool? ?? d.includeSilent,
        phoneFallback: j['phoneFallback'] as bool? ?? d.phoneFallback,
        buzzSequence: _sequenceOf(j['buzzSequence']) ?? d.buzzSequence,
        appSequences: {
          if (j['appSequences'] case final Map m)
            for (final e in m.entries)
              '${e.key}': ?_sequenceOf(e.value),
        },
      );

  /// A stored sequence that no longer validates is dropped, not fatal: it
  /// falls back to the default instead of taking the whole relay config down.
  static BuzzSequence? _sequenceOf(Object? raw) {
    if (raw == null) return null;
    try {
      return BuzzSequence.fromJson(raw);
    } on FormatException {
      return null;
    }
  }
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
/// unknown), onlyWhileWorn (one setting for the relay), packages,
/// staleAfterMs, minuteOfDay, and the global quiet hours quietEnabled,
/// quietStartMin, quietEndMin (absent: no global quiet hours).
class RelayController {
  RelayController({
    required this.dispatcher,
    required this.buzz,
    required this.phone,
    required this.policy,
    required this.nowMs,
    this.onChanged,
    this.playSequence,
    this.deliverSequence,
    this.sequenceTimeout,
  });
  final AlertDispatcher dispatcher;
  final Future<bool> Function(List<int> pattern) buzz;

  /// Plays a user-chosen rhythm as one band delivery. When set, it replaces the
  /// fixed one-buzz pattern unless the channel mirrors the app's own haptics.
  final Future<bool> Function(BuzzSequence)? playSequence;

  /// [playSequence] that can say what it did to the band, preferred when set:
  /// the dispatcher then keeps its claim after a partial or unanswered delivery.
  final Future<BuzzDelivery> Function(BuzzSequence)? deliverSequence;

  /// How long [sequence] needs to play on the connected band (8AC: a compiled
  /// plan outlasts the taps' estimate). Null: its own transport timeout.
  final Duration Function(BuzzSequence)? sequenceTimeout;
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
  final Map<String, int> _removals = {};
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
    bool? overrideQuietHours,
    bool? allowDuringDnd,
    bool? includeVibrate,
    bool? includeSilent,
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
      overrideQuietHours: overrideQuietHours,
      allowDuringDnd: allowDuringDnd,
      includeVibrate: includeVibrate,
      includeSilent: includeSilent,
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
      if (_live.remove(key)) {
        // A repost of this key is a new occurrence even if the system reuses
        // the post time; the count is part of its delivery id.
        if (_removals.length >= 1000) _removals.clear();
        _removals[key] = (_removals[key] ?? 0) + 1;
      }
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
      // The channel's own window when it overrides, else the global one.
      final bool quiet;
      final int? start, end;
      if (cfg.overrideQuietHours) {
        start = cfg.quietStartMinute;
        end = cfg.quietEndMinute;
        quiet = true;
      } else {
        start = env['quietStartMin'] as int?;
        end = env['quietEndMin'] as int?;
        quiet = env['quietEnabled'] == true;
      }
      if (quiet && start != null && end != null) {
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
      final play = playSequence;
      final sequence = play == null || cfg.matchHaptics
          ? null
          : channel == 'apps'
              ? cfg.sequenceForApp('${m['package']}')
              : cfg.effectiveSequence;
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
        // Stable for one post (channel, key, post time, removals seen), so the
        // dispatcher's durable ledger refuses a second buzz for it after a
        // process restart empties the live-key set.
        eventId: '$channel:$key:$postMs:${_removals[key] ?? 0}',
        sourceTime: DateTime.fromMillisecondsSinceEpoch(postMs),
        historical: false,
        phoneTransport: phone,
        bandTimeout: sequence == null
            ? null
            : sequenceTimeout?.call(sequence) ?? sequence.transportTimeout,
        bandTransport: sequence == null
            ? () => buzz(pattern)
            : () => play!(sequence),
        bandDelivery: sequence == null || deliverSequence == null
            ? null
            : () => deliverSequence!(sequence),
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
    this.buzzForDuration,
    required this.isConnected,
    AlertDispatcher? dispatcher,
    this.worn,
    this.deliverSequence,
    this.sequenceTimeout,
    this.runBand,
    @visibleForTesting this.debugSupported,
    @visibleForTesting this.nativeTimeout = const Duration(seconds: 5),
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

  /// How long any one platform call may take.
  final Duration nativeTimeout;

  /// Every platform call is bounded: a bridge that never answers (engine torn
  /// down, service dying) must not leave a caller awaiting forever. The
  /// settings-page launch returns at once natively, so it is bounded too.
  Duration get _nativeTimeout => nativeTimeout;
  Timer? _healTimer;

  /// Fire the strap haptic. Wired by AppState to `engine.buzz()`. Best-effort.
  final Future<void> Function() buzz;
  final Future<bool> Function(int holdMs)? buzzForDuration;

  /// The app's one band delivery for a rhythm (8AC): the global band queue and
  /// the compiled commands of a WHOOP MG. When set, every rhythm of the relay
  /// goes through it instead of [buzz] and [buzzForDuration].
  final Future<BuzzDelivery> Function(BuzzSequence)? deliverSequence;

  /// How long [deliverSequence] needs for a rhythm on the connected band.
  final Duration Function(BuzzSequence)? sequenceTimeout;

  /// Runs a job of [commands] band commands in the global band queue. When
  /// set, the matched-haptics pulses go through it.
  final Future<BuzzDelivery> Function(
    int commands,
    Future<BuzzDelivery> Function(BandJobToken job) job,
  )? runBand;

  /// Whether the band is currently connected (no point buzzing nothing).
  final bool Function() isConnected;

  static const _kEnabled = 'notif_relay_enabled';
  static const _kOnlyWorn = 'notif_relay_only_worn';
  static const _kPackages = 'notif_relay_packages';
  static const _kSeen = 'notif_relay_seen';
  static const _kChannels = 'notif_relay_channels';

  /// How many apps the "seen" list remembers. A phone posts from a long tail
  /// of packages over a week; past this the list stops being a list you can
  /// read.
  static const int maxSeen = 60;

  /// Only Android can observe other apps' notifications, and only while
  /// FeatureFlag.nativeRelay is on. Everything below is a no-op when this is
  /// false, and the UI hides the feature entirely.
  bool get supported =>
      (debugSupported ?? Platform.isAndroid) &&
      FeatureFlags.isOn(FeatureFlag.nativeRelay);

  /// Tests only: pretend to be (or not be) Android.
  final bool? debugSupported;

  bool _enabled = false;
  bool get enabled => _enabled;

  /// One setting for the whole relay: hold every buzz unless the band reports
  /// it is on the wrist. Off by default. The report comes from [worn].
  bool _onlyWhileWorn = false;
  bool get onlyWhileWorn => _onlyWhileWorn;

  Future<void> setOnlyWhileWorn(bool on) async {
    if (on == _onlyWhileWorn) return;
    _onlyWhileWorn = on;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kOnlyWorn, on);
  }

  /// The band's wear report right now: worn, notWorn or unknown.
  String get wearReport => worn?.call() ?? 'unknown';

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
    playSequence: (s) async {
      final deliver = deliverSequence;
      if (deliver != null) return await deliver(s) == BuzzDelivery.complete;
      return playBuzzSequence(
        s,
        buzz: () async {
          await buzz();
          return true;
        },
        buzzForDuration: buzzForDuration,
        isConnected: isConnected,
      );
    },
    deliverSequence: (s) =>
        deliverSequence?.call(s) ??
        deliverBuzzSequence(
          s,
          buzz: () async {
            await buzz();
            return true;
          },
          buzzForDuration: buzzForDuration,
          isConnected: isConnected,
        ),
    sequenceTimeout: sequenceTimeout,
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
    Future<bool> Function(BuzzSequence)? playSequence,
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
      playSequence: playSequence,
    );
  }

  @visibleForTesting
  Map<String, Object?> debugPolicy(Map<String, Object?> m) => _policy(m);

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
    'onlyWhileWorn': _onlyWhileWorn,
    'worn': wearReport,
    'packages': _packages.toList(),
    // The global quiet hours, from the cache the policy can read synchronously.
    if (_globalQuiet case final q?) ...{
      'quietEnabled': q.quietEnabled,
      'quietStartMin': q.quietStartMin,
      'quietEndMin': q.quietEndMin,
    },
  };

  // Alerts' quiet hours as last loaded or saved. Null until bootstrap has read
  // them, which reads as "no global quiet hours".
  NotificationPrefs? _globalQuiet;
  StreamSubscription<NotificationPrefs>? _prefsSub;

  Future<void> _loadGlobalQuiet() async {
    try {
      _globalQuiet = await NotificationPrefs.load();
    } catch (_) {
      /* unreadable prefs: keep what we had */
    }
  }

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
    Future<bool> play(BandJobToken? job) async {
      for (var i = 0; i < pulses; i++) {
        if (i > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
        if (job == null) {
          await buzz();
        } else if (!await job.write(() async {
          await buzz();
          return true;
        })) {
          return false;
        }
      }
      return true;
    }

    final queued = runBand;
    if (queued == null) return play(null);
    return await queued(
          pulses,
          (job) async =>
              await play(job) ? BuzzDelivery.complete : BuzzDelivery.rejected,
        ) ==
        BuzzDelivery.complete;
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
    if (!supported) {
      // Switched off by FeatureFlag.nativeRelay on a phone that could relay:
      // tell the platform to stop sending metadata that nothing will read.
      if ((debugSupported ?? Platform.isAndroid)) await _disarmNative();
      return;
    }
    // Every save of the alert prefs, from any screen, refreshes the cache.
    _prefsSub ??= NotificationPrefs.onSaved.listen((p) => _globalQuiet = p);
    await _loadGlobalQuiet();
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _onlyWhileWorn = prefs.getBool(_kOnlyWorn) ?? false;
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

  Future<void> _disarmNative() async {
    try {
      await _native.invokeMethod('setArmed', false).timeout(_nativeTimeout);
    } catch (_) {
      /* no bridge, or it did not answer: nothing to disarm */
    }
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
      _granted = await _native
              .invokeMethod<bool>('isPermissionGranted')
              .timeout(_nativeTimeout) ??
          false;
    } on TimeoutException {
      // No answer is not a revocation: keep what was last known rather than
      // clearing every latch over a slow bridge. The next resume asks again.
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
      await _native.invokeMethod('requestPermission').timeout(_nativeTimeout);
    } catch (_) {
      /* user may just back out */
    }
    final ok = await refreshPermission();
    _resync();
    return ok;
  }

  bool get _anyChannelOn => controller.channels.values.any((c) => c.enabled);

  /// The one way a channel's own "Relay to the band" switch changes. The relay
  /// exists only to buzz the band, so a channel reading On has to be able to
  /// buzz: switching one on switches the relay on, and switching the last one
  /// off switches the relay off.
  Future<void> setChannel(String name, ChannelConfig next) async {
    controller.putChannel(name, next);
    if (next.enabled && !_enabled) {
      await setEnabled(true);
    } else if (!next.enabled && _enabled && !_anyChannelOn) {
      await setEnabled(false);
    }
  }

  Future<void> setEnabled(bool on) async {
    if (!supported || on == _enabled) return;
    // Switching the relay on with nothing armed would read On and do nothing.
    if (on && !_anyChannelOn) {
      controller.putChannel(
        'apps',
        controller.channels['apps']!.copyWith(enabled: true),
      );
    }
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
  int _resyncGen = 0;

  void _resync() {
    final shouldListen = active;
    final gen = ++_resyncGen;
    // Our own latches clear whether or not the bridge ever answers: a platform
    // that times out must not leave a disarmed relay believing it is listening.
    if (!shouldListen) unawaited(controller.stop('disarmed'));
    _native
        .invokeMethod('setArmed', shouldListen)
        .timeout(_nativeTimeout)
        .then((_) async {
      if (shouldListen) {
        final list = await _native
            .invokeMethod<List<Object?>>('activeMetadata')
            .timeout(_nativeTimeout);
        // A newer resync, a revocation or a switch-off while the bridge was
        // answering supersedes this one: do not re-open a closed listener.
        if (gen != _resyncGen || !active) return;
        await controller.listenerConnected(list ?? const []);
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
      final bound = await _native
              .invokeMethod<bool>('isConnected')
              .timeout(_nativeTimeout) ??
          true;
      if (!bound) {
        await _native.invokeMethod('rebind').timeout(_nativeTimeout);
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
    _prefsSub?.cancel();
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
