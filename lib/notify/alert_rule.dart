import 'buzz_sequence.dart';

/// Delivery targets are independent of where a rule executes.
enum AlertExecutionMode { bandNative, phoneLive, osScheduled, phoneDerived }

enum AlertFallback { none, phoneIfBandUnavailable }

enum AlertHistoricalReplay { liveOnly, ask, historical }

class AlertRule {
  static const phone = 1;
  static const band = 2;
  final String id;
  final String kind;
  final bool enabled;
  final int destinations;
  final AlertExecutionMode executionMode;
  final AlertFallback fallback;
  final Duration staleAfter;
  final AlertHistoricalReplay historicalReplay;
  final String channelPolicyId;

  /// The user's own buzz rhythm for this rule, or null for the registry
  /// default ([NotificationPrefs.buzzSequenceFor]).
  final BuzzSequence? buzzSequence;

  const AlertRule({
    required this.id,
    required this.kind,
    required this.destinations,
    this.enabled = true,
    this.executionMode = AlertExecutionMode.phoneDerived,
    this.fallback = AlertFallback.none,
    this.staleAfter = const Duration(seconds: 30),
    this.historicalReplay = AlertHistoricalReplay.liveOnly,
    required this.channelPolicyId,
    this.buzzSequence,
  }) : assert(destinations >= 0 && destinations <= 3);

  bool get phoneSelected => enabled && destinations & phone != 0;
  bool get bandSelected => enabled && destinations & band != 0;
  int get staleAfterSeconds => staleAfter.inSeconds;

  factory AlertRule.fromJson(Map<String, dynamic> json) {
    T parse<T extends Enum>(List<T> values, Object? raw, T fallback) =>
        values.where((v) => v.name == raw).firstOrNull ?? fallback;
    final mask = json['destinations'];
    if (mask is! int || mask < 0 || mask > 3) {
      throw const FormatException('Invalid alert destination mask');
    }
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Missing alert rule id');
    }
    final seconds = json['staleAfterSeconds'];
    if (seconds != null && (seconds is! int || seconds < 0)) {
      throw const FormatException('Invalid alert expiration');
    }
    return AlertRule(
      id: id,
      kind: json['kind'] as String? ?? id,
      enabled: (json['enabled'] as bool? ?? mask != 0) && mask != 0,
      destinations: mask,
      executionMode: parse(
        AlertExecutionMode.values,
        json['executionMode'],
        AlertExecutionMode.phoneDerived,
      ),
      fallback: parse(
        AlertFallback.values,
        json['fallback'],
        AlertFallback.none,
      ),
      staleAfter: Duration(seconds: seconds as int? ?? 30),
      historicalReplay: parse(
        AlertHistoricalReplay.values,
        json['historicalReplay'],
        AlertHistoricalReplay.liveOnly,
      ),
      channelPolicyId: json['channelPolicyId'] as String? ?? id,
      buzzSequence: json['buzzSequence'] == null
          ? null
          : BuzzSequence.fromJson(json['buzzSequence']),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'enabled': enabled && destinations != 0,
    'destinations': enabled ? destinations : 0,
    'executionMode': executionMode.name,
    'fallback': fallback.name,
    'staleAfterSeconds': staleAfter.inSeconds,
    'historicalReplay': historicalReplay.name,
    'channelPolicyId': channelPolicyId,
    if (buzzSequence != null) 'buzzSequence': buzzSequence!.toJson(),
  };

  AlertRule copyWith({
    bool? enabled,
    int? destinations,
    AlertExecutionMode? executionMode,
    AlertFallback? fallback,
    Duration? staleAfter,
    AlertHistoricalReplay? historicalReplay,
    String? channelPolicyId,
    BuzzSequence? buzzSequence,
  }) => AlertRule(
    id: id,
    kind: kind,
    enabled: enabled ?? this.enabled,
    destinations: destinations ?? this.destinations,
    executionMode: executionMode ?? this.executionMode,
    fallback: fallback ?? this.fallback,
    staleAfter: staleAfter ?? this.staleAfter,
    historicalReplay: historicalReplay ?? this.historicalReplay,
    channelPolicyId: channelPolicyId ?? this.channelPolicyId,
    buzzSequence: buzzSequence ?? this.buzzSequence,
  );
}

/// Execution modes supported by the actual producers, and their target-specific
/// requirements. Device capability sets come from the connected adapter.
class AlertCapabilityRegistry {
  /// Current edge transports are verified only for WHOOP family entries.
  /// A connected generic heart-rate adapter does not acquire haptic support.
  static Set<String> targetsForBandFamily(String? family) => {
    'phone', if (family == 'gen4' || family == 'gen5') 'band',
  };

  static const scheduledKinds = {
    'water',
    'meds',
    'movement',
    'checkIn',
    'windDown',
  };
  static const liveKinds = {
    'zone',
    'wake',
    'breath',
    'tasker',
    'relay',
    'gesture',
    'buzzPreview',
    'hardwareProbe',
  };
  static const derivedKinds = {
    'health',
    'recovery',
    'reminders',
    'device',
    'autoDetect',
    'stepGoal',
    'alarmLatchFailed',
    'alarmNightCheck',
    'alarm',
  };
  static const liveBandModes = {AlertExecutionMode.phoneLive};
  static const phoneModes = {
    AlertExecutionMode.osScheduled,
    AlertExecutionMode.phoneDerived,
  };

  static Set<AlertExecutionMode> supportedExecutionModes(String kind) {
    if (kind == 'nativeAlarm') return const {AlertExecutionMode.bandNative};
    if (scheduledKinds.contains(kind)) {
      return const {
        AlertExecutionMode.osScheduled,
        AlertExecutionMode.phoneLive,
      };
    }
    if (liveKinds.contains(kind)) return const {AlertExecutionMode.phoneLive};
    if (derivedKinds.contains(kind)) {
      return const {AlertExecutionMode.phoneDerived};
    }
    return const {};
  }

  /// A system schedule owns phone reminders while their band buzz still needs
  /// a running phone and live link. Phone-derived events need that link too
  /// when the selected destination is the band.
  static AlertExecutionMode? effectiveMode(AlertRule rule, String target) {
    if (target != 'phone' && target != 'band') return null;
    if (!supportedExecutionModes(rule.kind).contains(rule.executionMode)) {
      return null;
    }
    if (rule.executionMode == AlertExecutionMode.bandNative) {
      if (target == 'band') return AlertExecutionMode.bandNative;
      return null;
    }
    if (target == 'band') return AlertExecutionMode.phoneLive;
    if (scheduledKinds.contains(rule.kind)) {
      return AlertExecutionMode.osScheduled;
    }
    return AlertExecutionMode.phoneDerived;
  }

  static String? destinationSupportReason(
    AlertRule rule,
    String target, {
    Set<String> supportedTargets = const {'phone', 'band'},
    Set<AlertExecutionMode> supportedBandModes = liveBandModes,
    Set<AlertExecutionMode> supportedPhoneModes = phoneModes,
  }) {
    if (target != 'phone' && target != 'band') return 'unknownTarget';
    if (!supportedTargets.contains(target)) return 'unsupportedTarget';
    // These schedules currently have an OS phone producer only. Selecting
    // Band cannot create a timer implementation that does not exist.
    if (target == 'band' && const {'checkIn', 'windDown', 'reminders',
        'alarmNightCheck'}.contains(rule.kind)) {
      return 'bandScheduleUnavailable';
    }
    final allowed = supportedExecutionModes(rule.kind);
    if (allowed.isEmpty) return 'unsupportedRuleKind';
    if (!allowed.contains(rule.executionMode)) return 'unsupportedExecution';
    final mode = effectiveMode(rule, target);
    if (mode == null) return 'unsupportedDestinationExecution';
    final modes = target == 'band' ? supportedBandModes : supportedPhoneModes;
    return modes.contains(mode) ? null : 'unsupportedDeviceExecution';
  }

  static String describe(AlertExecutionMode mode) => switch (mode) {
    AlertExecutionMode.bandNative => 'On band, works without phone',
    AlertExecutionMode.phoneLive => 'On band, phone must be connected',
    AlertExecutionMode.osScheduled => 'On phone, scheduled by the system',
    AlertExecutionMode.phoneDerived => 'On phone, Edge must be running',
  };

  static String summary(
    AlertRule rule, {
    bool bandConnected = true,
    bool bandSupported = true,
    bool phoneSupported = true,
    Set<AlertExecutionMode> supportedBandModes = liveBandModes,
    Set<AlertExecutionMode> supportedPhoneModes = phoneModes,
  }) {
    if (!rule.enabled || rule.destinations == 0) return 'Off';
    final targets = <String>{
      if (rule.phoneSelected) 'phone',
      if (rule.bandSelected) 'band',
    };
    final supported = <String>{
      if (phoneSupported) 'phone',
      if (bandSupported) 'band',
    };
    return targets
        .map((target) {
          final reason = destinationSupportReason(
            rule,
            target,
            supportedTargets: supported,
            supportedBandModes: supportedBandModes,
            supportedPhoneModes: supportedPhoneModes,
          );
          if (reason != null) {
            return target == 'phone'
                ? 'Phone delivery is unsupported'
                : 'Band delivery is unsupported';
          }
          final mode = effectiveMode(rule, target)!;
          final label = describe(mode);
          return target == 'band' &&
                  !bandConnected &&
                  mode != AlertExecutionMode.bandNative
              ? 'Band disconnected. $label'
              : label;
        })
        .join('; ');
  }
}
