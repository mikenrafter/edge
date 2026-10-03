// Alert destinations, execution policies, and legacy notification switches.
// The versioned SharedPreferences blob owns destinations and rule policies. Legacy
// keys are migrated once and remain mirrors for existing headless consumers.
// The in-app feed is always written, regardless of outbound delivery settings.

import 'dart:async';
import 'dart:convert';

import 'alert_rule.dart';
import 'buzz_sequence.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_event.dart';
import 'tap_router.dart';

class NotificationPrefs {
  static const schemaVersion = 1;
  static const storageKey = 'notif_alert_rules_v1';
  final Map<String, AlertRule> alertRules;

  /// The day's aggregated health exception (illness, unusual physiology,
  /// elevated temperature, an irregular-rhythm screen, low readiness, a shifted
  /// resting-HR trend — one notification, not six).
  final bool healthEnabled;

  /// Retained for storage compatibility. Nothing on the `recovery` channel is
  /// one of the three sanctioned classes any more — see [classOf].
  final bool recoveryEnabled;

  /// The weekly lookback.
  final bool remindersEnabled;

  /// The band's own failures: flat battery, on the charger, gone quiet. This
  /// used to be hard-coded enabled with no switch anywhere.
  final bool deviceEnabled;

  /// Quiet window as minutes-from-midnight. Wraps midnight when start > end
  /// (e.g. 22:00–07:00 → start=1320, end=420).
  final int quietStartMin;
  final int quietEndMin;
  final bool quietEnabled;

  /// When true, NotifPriority.critical events fire even inside quiet hours.
  final bool criticalOverridesQuiet;

  /// Water reminder: a recurring strap buzz across the waking window, every
  /// [waterIntervalMin] minutes. It is a nudge to LOG a drink and nothing more
  /// — the app measures no hydration and claims none. Opt-in, off by default.
  final bool waterEnabled;

  /// How often the water buzz fires, in minutes. Clamped to
  /// [waterIntervalMinAllowed]..[waterIntervalMaxAllowed] when scheduling.
  final int waterIntervalMin;

  /// Allowed bounds for the water interval (30 min .. 6 h).
  static const int waterIntervalMinAllowed = 30;
  static const int waterIntervalMaxAllowed = 360;

  /// Whether the auto-detected-workout surfaces are on: the "did you work out?"
  /// notification and the review cards the detector feeds. Asked for twice
  /// (issues #102, #149) and never built — the detector has never had an off
  /// switch of any kind.
  ///
  /// WHAT IT DOES NOT DO: stop the detection itself. The bouts are computed
  /// inside the day derivation and written to `workout_suggestions` there; this
  /// switch silences every surface that shows them, which is the part the user
  /// experiences. The rows stay, unread, and turning it back on shows them
  /// again rather than losing a week of them.
  final bool autoDetectEnabled;

  /// The "time to move" nudge: a one-shot OS notification two hours after the
  /// last movement the band's live IMU saw, re-armed on every movement so it
  /// only ever fires on a genuinely uninterrupted still stretch.
  ///
  /// Opt-in, off by default, and it is what earns the nudge its place on
  /// [NotificationService.schedulableIds] — the rule that list enforces is that
  /// a scheduled slot must be one the user asked for by name. Without a switch
  /// it was refused, which is why it has never fired for anyone (issue #123).
  final bool movementEnabled;

  /// The medication reminder: one notification per scheduled dose the user
  /// entered themselves, and ONLY for a dose that is still upcoming — a slot
  /// already marked taken or deliberately skipped is not armed at all.
  ///
  /// This is the one prompt in the app whose time is not a guess: it is the
  /// schedule in `med_def.schedule_json`, which the user typed. Opt-in and off
  /// by default like every other outbound path, because someone who wants a
  /// water reminder has not thereby asked to be told about their pills.
  final bool medsEnabled;

  /// The daily check-in: one prompt, once, to write the day's self-report
  /// (mood, energy, stress, soreness, sleep quality — the whole journal, not
  /// one field at a time).
  ///
  /// Suppressed for the day the moment any rating is written, so it can never
  /// ask for something already answered. It is NOT armed for a day that was
  /// missed — there is no catching up on a self-report, and a prompt that
  /// fires because yesterday is blank is a streak wearing a different hat.
  final bool checkInEnabled;

  /// The low-battery alert threshold, in percent. DeviceAlerts used to
  /// hard-code 15%; this is the same alert with the number in the user's
  /// hands. Read back by DeviceAlerts through its own persisted store (same
  /// key), so a headless BLE state update picks up a change without a full
  /// NotificationPrefs load. Clamped to [batteryPctAllowed] when scheduling.
  final int batteryAlertPct;

  /// The step-goal achievement: one note on the day the step ESTIMATE first
  /// crosses the user's goal. On by default — it fires at most once a day and
  /// only when the goal is actually reached — with this as its off switch.
  final bool stepGoalEnabled;

  /// The nightly wind-down nudge: one heads-up before the bedtime the Sleep
  /// Coach LEARNED from this user's own nights. Opt-in and off by default like
  /// every other outbound scheduled nudge; it also stays silent until a
  /// bedtime has actually been learned — see NotificationCenter.windDownSlot.
  final bool windDownEnabled;

  /// The alarm safety notifications (weekly-schedule feature). Both default
  /// ON, unlike every other reminder above: they exist to catch a wake alarm
  /// that silently isn't going to fire, which is the one failure mode where
  /// starting silent defeats the point.
  ///
  /// Latch-failure: the strap never confirmed (event 56) an arm this app
  /// wrote, after the retry AlarmConfirmation's grace window already allows.
  final bool alarmLatchFailedEnabled;

  /// The 7pm "no alarm set for tonight" check-in: silent whenever an alarm IS
  /// armed for tonight, so it only ever speaks up about an actual gap.
  final bool alarmNightCheckEnabled;

  /// Allowed bounds for [batteryAlertPct]. Below 5% a band is dying, not low;
  /// above 40% the alert would fire constantly and be muted forever.
  static const int batteryPctMin = 5;
  static const int batteryPctMax = 40;

  /// The shipped default threshold — what an unset store degrades to (also
  /// DeviceAlerts' fallback, so the number is spelled exactly once).
  static const int batteryPctDefault = 15;

  const NotificationPrefs({
    this.alertRules = const {},
    this.healthEnabled = true,
    this.recoveryEnabled = true,
    this.remindersEnabled = true,
    this.deviceEnabled = true,
    this.quietEnabled = true,
    this.quietStartMin = 22 * 60, // 22:00
    this.quietEndMin = 7 * 60, // 07:00
    this.criticalOverridesQuiet = true,
    this.waterEnabled = false,
    this.waterIntervalMin = 120, // every 2 hours
    this.autoDetectEnabled = true,
    this.movementEnabled = false,
    this.medsEnabled = false,
    this.checkInEnabled = false,
    this.batteryAlertPct = batteryPctDefault,
    this.stepGoalEnabled = true,
    this.windDownEnabled = false,
    this.alarmLatchFailedEnabled = true,
    this.alarmNightCheckEnabled = true,
  });

  static const _kHealth = 'notif_health';
  static const _kRecovery = 'notif_recovery';
  static const _kReminders = 'notif_reminders';
  static const _kDevice = 'notif_device';
  static const _kQuietEnabled = 'notif_quiet_enabled';
  static const _kQuietStart = 'notif_quiet_start';
  static const _kQuietEnd = 'notif_quiet_end';
  static const _kCriticalOverride = 'notif_critical_override';
  static const _kWater = 'notif_water';
  static const _kWaterInterval = 'notif_water_interval';
  static const _kAutoDetect = 'notif_auto_detect';
  static const _kMovement = 'notif_movement';
  static const _kMeds = 'notif_meds';
  static const _kCheckIn = 'notif_checkin';

  /// The low-battery alert threshold's persisted key. PUBLIC because
  /// DeviceAlerts reads it back through its own store seam on headless BLE
  /// state updates, without loading a full [NotificationPrefs]. Both sides of
  /// that coupling must spell it once.
  static const String batteryPctPrefKey = 'notif_battery_pct';
  static const _kBatteryPct = batteryPctPrefKey;
  static const _kStepGoal = 'notif_stepgoal';
  static const _kWindDown = 'notif_winddown';
  static const _kAlarmLatchFailed = 'notif_alarm_latch_failed';
  static const _kAlarmNightCheck = 'notif_alarm_night_check';

  static Future<void> _storeTail = Future.value();

  static Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _storeTail.then((_) => action());
    _storeTail = next.then<void>((_) {}, onError: (Object _, StackTrace trace) {});
    return next;
  }

  static Future<NotificationPrefs> load() => _serialize(_load);

  static Future<NotificationPrefs> _load() async {
    final p = await SharedPreferences.getInstance();
    final stored = p.getString(storageKey);
    if (stored != null) {
      // Once written, the blob owns rule policies. Legacy flags cannot
      // re-run migration or add a destination the user removed.
      final rules = NotificationPrefs.fromJson(
        Map<String, dynamic>.from(jsonDecode(stored) as Map),
      );
      // Existing background consumers can adjust quiet hours and schedule
      // settings without changing delivery targets or re-running migration.
      return rules.copyWith(
        quietEnabled: p.getBool(_kQuietEnabled) ?? rules.quietEnabled,
        quietStartMin: p.getInt(_kQuietStart) ?? rules.quietStartMin,
        quietEndMin: p.getInt(_kQuietEnd) ?? rules.quietEndMin,
        criticalOverridesQuiet:
            p.getBool(_kCriticalOverride) ?? rules.criticalOverridesQuiet,
        waterIntervalMin: p.getInt(_kWaterInterval) ?? rules.waterIntervalMin,
        batteryAlertPct: (p.getInt(_kBatteryPct) ?? rules.batteryAlertPct)
            .clamp(batteryPctMin, batteryPctMax)
            .toInt(),
      );
    }
    final legacy = NotificationPrefs(
      healthEnabled: p.getBool(_kHealth) ?? true,
      recoveryEnabled: p.getBool(_kRecovery) ?? true,
      remindersEnabled: p.getBool(_kReminders) ?? true,
      deviceEnabled: p.getBool(_kDevice) ?? true,
      quietEnabled: p.getBool(_kQuietEnabled) ?? true,
      quietStartMin: p.getInt(_kQuietStart) ?? 22 * 60,
      quietEndMin: p.getInt(_kQuietEnd) ?? 7 * 60,
      criticalOverridesQuiet: p.getBool(_kCriticalOverride) ?? true,
      waterEnabled: p.getBool(_kWater) ?? false,
      waterIntervalMin: p.getInt(_kWaterInterval) ?? 120,
      autoDetectEnabled: p.getBool(_kAutoDetect) ?? true,
      movementEnabled: p.getBool(_kMovement) ?? false,
      medsEnabled: p.getBool(_kMeds) ?? false,
      checkInEnabled: p.getBool(_kCheckIn) ?? false,
      batteryAlertPct: ((p.getInt(_kBatteryPct) ?? batteryPctDefault).clamp(
        batteryPctMin,
        batteryPctMax,
      )).toInt(),
      stepGoalEnabled: p.getBool(_kStepGoal) ?? true,
      windDownEnabled: p.getBool(_kWindDown) ?? false,
      alarmLatchFailedEnabled: p.getBool(_kAlarmLatchFailed) ?? true,
      alarmNightCheckEnabled: p.getBool(_kAlarmNightCheck) ?? true,
    );
    final migrated = legacy.copyWith(
      alertRules: {
        ...legacy.effectiveAlertRules,
        'zone': legacyRule(
          'zone',
          p.getBool('workout.zone_alert_enabled') ?? false,
          2,
        ),
        'relay': legacyRule(
          'relay',
          p.getBool('notif_relay_enabled') ?? false,
          2,
        ),
        'gesture': legacyRule(
          'gesture',
          (p.getString('gesture_double_tap') ?? 'none') != 'none',
          2,
        ),
        'wake': legacyRule('wake', true, 2),
      },
    );
    if (!await p.setString(storageKey, jsonEncode(migrated.toJson()))) {
      throw StateError('Unable to migrate alert preferences');
    }
    return migrated;
  }

  Future<void> save() => _serialize(_save);

  static final StreamController<NotificationPrefs> _saved =
      StreamController<NotificationPrefs>.broadcast();

  /// Every successful [save], with what was written. The one place a consumer
  /// that caches a pref (the relay's global quiet hours) can hear a change
  /// from any screen or scheduler that saves.
  static Stream<NotificationPrefs> get onSaved => _saved.stream;

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    // One write commits every destination and policy together. The old keys
    // remain mirrors for headless consumers still using the legacy seam.
    if (!await p.setString(storageKey, jsonEncode(toJson()))) {
      throw StateError('Unable to save alert preferences');
    }
    await p.setBool(_kHealth, healthEnabled);
    await p.setBool(_kRecovery, recoveryEnabled);
    await p.setBool(_kReminders, remindersEnabled);
    await p.setBool(_kDevice, deviceEnabled);
    await p.setBool(_kQuietEnabled, quietEnabled);
    await p.setInt(_kQuietStart, quietStartMin);
    await p.setInt(_kQuietEnd, quietEndMin);
    await p.setBool(_kCriticalOverride, criticalOverridesQuiet);
    await p.setBool(_kWater, waterEnabled);
    await p.setInt(_kWaterInterval, waterIntervalMin);
    await p.setBool(_kAutoDetect, autoDetectEnabled);
    await p.setBool(_kMovement, movementEnabled);
    await p.setBool(_kMeds, medsEnabled);
    await p.setBool(_kCheckIn, checkInEnabled);
    await p.setInt(
      _kBatteryPct,
      batteryAlertPct.clamp(batteryPctMin, batteryPctMax).toInt(),
    );
    await p.setBool(_kStepGoal, stepGoalEnabled);
    await p.setBool(_kWindDown, windDownEnabled);
    await p.setBool(_kAlarmLatchFailed, alarmLatchFailedEnabled);
    await p.setBool(_kAlarmNightCheck, alarmNightCheckEnabled);
    await p.setBool('workout.zone_alert_enabled', alertRule('zone').enabled);
    await p.setBool('notif_relay_enabled', alertRule('relay').enabled);
    _saved.add(this);
  }

  NotificationPrefs copyWith({
    Map<String, AlertRule>? alertRules,
    bool? healthEnabled,
    bool? recoveryEnabled,
    bool? remindersEnabled,
    bool? deviceEnabled,
    bool? quietEnabled,
    int? quietStartMin,
    int? quietEndMin,
    bool? criticalOverridesQuiet,
    bool? waterEnabled,
    int? waterIntervalMin,
    bool? autoDetectEnabled,
    bool? movementEnabled,
    bool? medsEnabled,
    bool? checkInEnabled,
    int? batteryAlertPct,
    bool? stepGoalEnabled,
    bool? windDownEnabled,
    bool? alarmLatchFailedEnabled,
    bool? alarmNightCheckEnabled,
  }) {
    final rules = {...effectiveAlertRules, ...?alertRules};
    if (healthEnabled != null) {
      final old = rules['health']!;
      rules['health'] = old.copyWith(
        enabled: healthEnabled,
        destinations: healthEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (recoveryEnabled != null) {
      final old = rules['recovery']!;
      rules['recovery'] = old.copyWith(
        enabled: recoveryEnabled,
        destinations: recoveryEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (remindersEnabled != null) {
      final old = rules['reminders']!;
      rules['reminders'] = old.copyWith(
        enabled: remindersEnabled,
        destinations: remindersEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (deviceEnabled != null) {
      final old = rules['device']!;
      rules['device'] = old.copyWith(
        enabled: deviceEnabled,
        destinations: deviceEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (waterEnabled != null) {
      final old = rules['water']!;
      rules['water'] = old.copyWith(
        enabled: waterEnabled,
        destinations: waterEnabled
            ? (old.destinations == 0 ? 3 : old.destinations)
            : 0,
      );
    }
    if (autoDetectEnabled != null) {
      final old = rules['autoDetect']!;
      rules['autoDetect'] = old.copyWith(
        enabled: autoDetectEnabled,
        destinations: autoDetectEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (movementEnabled != null) {
      final old = rules['movement']!;
      rules['movement'] = old.copyWith(
        enabled: movementEnabled,
        destinations: movementEnabled
            ? (old.destinations == 0 ? 3 : old.destinations)
            : 0,
      );
    }
    if (medsEnabled != null) {
      final old = rules['meds']!;
      rules['meds'] = old.copyWith(
        enabled: medsEnabled,
        destinations: medsEnabled
            ? (old.destinations == 0 ? 3 : old.destinations)
            : 0,
      );
    }
    if (checkInEnabled != null) {
      final old = rules['checkIn']!;
      rules['checkIn'] = old.copyWith(
        enabled: checkInEnabled,
        destinations: checkInEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (stepGoalEnabled != null) {
      final old = rules['stepGoal']!;
      rules['stepGoal'] = old.copyWith(
        enabled: stepGoalEnabled,
        destinations: stepGoalEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (windDownEnabled != null) {
      final old = rules['windDown']!;
      rules['windDown'] = old.copyWith(
        enabled: windDownEnabled,
        destinations: windDownEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (alarmLatchFailedEnabled != null) {
      final old = rules['alarmLatchFailed']!;
      rules['alarmLatchFailed'] = old.copyWith(
        enabled: alarmLatchFailedEnabled,
        destinations: alarmLatchFailedEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    if (alarmNightCheckEnabled != null) {
      final old = rules['alarmNightCheck']!;
      rules['alarmNightCheck'] = old.copyWith(
        enabled: alarmNightCheckEnabled,
        destinations: alarmNightCheckEnabled
            ? (old.destinations == 0 ? 1 : old.destinations)
            : 0,
      );
    }
    return NotificationPrefs(
      alertRules: Map.unmodifiable(rules),
      healthEnabled:
          rules['health']!.enabled && rules['health']!.destinations != 0,
      recoveryEnabled:
          rules['recovery']!.enabled && rules['recovery']!.destinations != 0,
      remindersEnabled:
          rules['reminders']!.enabled && rules['reminders']!.destinations != 0,
      deviceEnabled:
          rules['device']!.enabled && rules['device']!.destinations != 0,
      quietEnabled: quietEnabled ?? this.quietEnabled,
      quietStartMin: quietStartMin ?? this.quietStartMin,
      quietEndMin: quietEndMin ?? this.quietEndMin,
      criticalOverridesQuiet:
          criticalOverridesQuiet ?? this.criticalOverridesQuiet,
      waterEnabled:
          rules['water']!.enabled && rules['water']!.destinations != 0,
      waterIntervalMin: waterIntervalMin ?? this.waterIntervalMin,
      autoDetectEnabled:
          rules['autoDetect']!.enabled &&
          rules['autoDetect']!.destinations != 0,
      movementEnabled:
          rules['movement']!.enabled && rules['movement']!.destinations != 0,
      medsEnabled: rules['meds']!.enabled && rules['meds']!.destinations != 0,
      checkInEnabled:
          rules['checkIn']!.enabled && rules['checkIn']!.destinations != 0,
      batteryAlertPct: batteryAlertPct ?? this.batteryAlertPct,
      stepGoalEnabled:
          rules['stepGoal']!.enabled && rules['stepGoal']!.destinations != 0,
      windDownEnabled:
          rules['windDown']!.enabled && rules['windDown']!.destinations != 0,
      alarmLatchFailedEnabled:
          rules['alarmLatchFailed']!.enabled &&
          rules['alarmLatchFailed']!.destinations != 0,
      alarmNightCheckEnabled:
          rules['alarmNightCheck']!.enabled &&
          rules['alarmNightCheck']!.destinations != 0,
    );
  }

  static AlertRule legacyRule(String id, bool enabled, int destinations) =>
      AlertRule(
        id: id,
        kind: id,
        enabled: enabled,
        destinations: enabled ? destinations : 0,
        executionMode: switch (id) {
          'nativeAlarm' => AlertExecutionMode.bandNative,
          'water' ||
          'meds' ||
          'movement' ||
          'zone' ||
          'wake' ||
          'breath' ||
          'tasker' ||
          'relay' ||
          'gesture' => AlertExecutionMode.phoneLive,
          'checkIn' || 'windDown' => AlertExecutionMode.osScheduled,
          _ => AlertExecutionMode.phoneDerived,
        },
        channelPolicyId: id,
      );

  Map<String, AlertRule> get effectiveAlertRules => {
    'health': legacyRule('health', healthEnabled, 1),
    'recovery': legacyRule('recovery', recoveryEnabled, 1),
    'reminders': legacyRule('reminders', remindersEnabled, 1),
    'device': legacyRule('device', deviceEnabled, 1),
    'water': legacyRule('water', waterEnabled, 3),
    'autoDetect': legacyRule('autoDetect', autoDetectEnabled, 1),
    'movement': legacyRule('movement', movementEnabled, 3),
    'meds': legacyRule('meds', medsEnabled, 3),
    'checkIn': legacyRule('checkIn', checkInEnabled, 1),
    'stepGoal': legacyRule('stepGoal', stepGoalEnabled, 1),
    'windDown': legacyRule('windDown', windDownEnabled, 1),
    'alarmLatchFailed': legacyRule(
      'alarmLatchFailed',
      alarmLatchFailedEnabled,
      1,
    ),
    'alarmNightCheck': legacyRule('alarmNightCheck', alarmNightCheckEnabled, 1),
    'alarm': legacyRule('alarm', true, 1),
    'nativeAlarm': legacyRule('nativeAlarm', true, 2),
    for (final id in ['zone', 'wake', 'breath', 'tasker', 'relay', 'gesture'])
      id: legacyRule(id, ['wake', 'breath', 'tasker'].contains(id), 2),
    ...alertRules,
  };

  AlertRule alertRule(String id) =>
      effectiveAlertRules[id] ?? legacyRule(id, false, 0);

  /// The rule registry's order. Default buzz sequences hang off these
  /// positions, so it is frozen: append new rules, never reorder or remove.
  static const List<String> alertRuleOrder = [
    'health',
    'recovery',
    'reminders',
    'device',
    'water',
    'autoDetect',
    'movement',
    'meds',
    'checkIn',
    'stepGoal',
    'windDown',
    'alarmLatchFailed',
    'alarmNightCheck',
    'alarm',
    'nativeAlarm',
    'zone',
    'wake',
    'breath',
    'tasker',
    'relay',
    'gesture',
  ];

  /// The rule's own buzz rhythm, else the default for its registry position
  /// (an unknown id takes the first one).
  BuzzSequence buzzSequenceFor(String ruleId) =>
      alertRule(ruleId).buzzSequence ??
      BuzzSequence.defaultFor(
          alertRuleOrder.indexOf(ruleId).clamp(0, alertRuleOrder.length));

  bool phoneDeliveryEnabled(String id) => alertRule(id).phoneSelected;
  bool bandDeliveryEnabled(String id) => alertRule(id).bandSelected;

  NotificationPrefs withAlertRule(Map<String, Object?> json) {
    final rule = AlertRule.fromJson(json);
    return copyWith(alertRules: {rule.id: rule});
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'preferences': {
      'healthEnabled': healthEnabled,
      'recoveryEnabled': recoveryEnabled,
      'remindersEnabled': remindersEnabled,
      'deviceEnabled': deviceEnabled,
      'quietEnabled': quietEnabled,
      'quietStartMin': quietStartMin,
      'quietEndMin': quietEndMin,
      'criticalOverridesQuiet': criticalOverridesQuiet,
      'waterEnabled': waterEnabled,
      'waterIntervalMin': waterIntervalMin,
      'autoDetectEnabled': autoDetectEnabled,
      'movementEnabled': movementEnabled,
      'medsEnabled': medsEnabled,
      'checkInEnabled': checkInEnabled,
      'batteryAlertPct': batteryAlertPct
          .clamp(batteryPctMin, batteryPctMax)
          .toInt(),
      'stepGoalEnabled': stepGoalEnabled,
      'windDownEnabled': windDownEnabled,
      'alarmLatchFailedEnabled': alarmLatchFailedEnabled,
      'alarmNightCheckEnabled': alarmNightCheckEnabled,
    },
    'rules': {
      for (final entry in effectiveAlertRules.entries)
        entry.key: entry.value.toJson(),
    },
  };

  factory NotificationPrefs.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw const FormatException(
        'Unsupported notification preferences version',
      );
    }
    final values = Map<String, dynamic>.from(json['preferences'] as Map);
    final defaults = const NotificationPrefs();
    final rules = Map<String, dynamic>.from(json['rules'] as Map);
    final prefs = NotificationPrefs(
      healthEnabled: values['healthEnabled'] as bool? ?? defaults.healthEnabled,
      recoveryEnabled:
          values['recoveryEnabled'] as bool? ?? defaults.recoveryEnabled,
      remindersEnabled:
          values['remindersEnabled'] as bool? ?? defaults.remindersEnabled,
      deviceEnabled: values['deviceEnabled'] as bool? ?? defaults.deviceEnabled,
      quietEnabled: values['quietEnabled'] as bool? ?? defaults.quietEnabled,
      quietStartMin: values['quietStartMin'] as int? ?? defaults.quietStartMin,
      quietEndMin: values['quietEndMin'] as int? ?? defaults.quietEndMin,
      criticalOverridesQuiet:
          values['criticalOverridesQuiet'] as bool? ??
          defaults.criticalOverridesQuiet,
      waterEnabled: values['waterEnabled'] as bool? ?? defaults.waterEnabled,
      waterIntervalMin:
          values['waterIntervalMin'] as int? ?? defaults.waterIntervalMin,
      autoDetectEnabled:
          values['autoDetectEnabled'] as bool? ?? defaults.autoDetectEnabled,
      movementEnabled:
          values['movementEnabled'] as bool? ?? defaults.movementEnabled,
      medsEnabled: values['medsEnabled'] as bool? ?? defaults.medsEnabled,
      checkInEnabled:
          values['checkInEnabled'] as bool? ?? defaults.checkInEnabled,
      batteryAlertPct:
          values['batteryAlertPct'] as int? ?? defaults.batteryAlertPct,
      stepGoalEnabled:
          values['stepGoalEnabled'] as bool? ?? defaults.stepGoalEnabled,
      windDownEnabled:
          values['windDownEnabled'] as bool? ?? defaults.windDownEnabled,
      alarmLatchFailedEnabled:
          values['alarmLatchFailedEnabled'] as bool? ??
          defaults.alarmLatchFailedEnabled,
      alarmNightCheckEnabled:
          values['alarmNightCheckEnabled'] as bool? ??
          defaults.alarmNightCheckEnabled,
    );
    return prefs.copyWith(
      alertRules: {
        for (final entry in rules.entries)
          entry.key: AlertRule.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
    );
  }

  bool categoryEnabled(NotifCategory c) => switch (c) {
    NotifCategory.health => healthEnabled,
    NotifCategory.recovery => recoveryEnabled,
    NotifCategory.reminders => remindersEnabled,
    NotifCategory.device => deviceEnabled,
  };

  /// True if [minuteOfDay] falls inside the quiet window (inclusive start,
  /// exclusive end), handling the midnight-wrap case.
  bool inQuietHours(int minuteOfDay) {
    if (!quietEnabled) return false;
    if (quietStartMin == quietEndMin) return false; // empty window
    if (quietStartMin < quietEndMin) {
      return minuteOfDay >= quietStartMin && minuteOfDay < quietEndMin;
    }
    // Wraps midnight: e.g. [22:00, 24:00) ∪ [00:00, 07:00)
    return minuteOfDay >= quietStartMin || minuteOfDay < quietEndMin;
  }

  /// The central gate: should this event be presented to the OS right now?
  ///
  /// This is also where the three-class rule is enforced — one gate rather than
  /// a check at each of the emit sites, which is how twenty-two kinds accreted
  /// in the first place.
  bool shouldFireOs(NotifEvent event, int minuteOfDay) {
    // The auto-detect off switch, applied before anything else: it is the one
    // gate the user set for THIS notification, and route is what identifies it
    // (the category it is emitted on is shared with everything else on the
    // recovery channel).
    // (On the PATH: the payload carries the bout as `?id=…`, and an equality
    // check against the bare route would miss every real one.)
    if (!autoDetectEnabled &&
        routePath(event.route ?? '') == kRouteWorkoutSuggestion) {
      return false;
    }
    // The movement nudge's off switch, same shape and same reason as the
    // auto-detect one above: the route identifies the event the user set THIS
    // switch for. Covers both sedentary surfaces — the OS-scheduled
    // two-hour-still one-shot (which never passes through here; it is gated at
    // NotificationService.schedulableIds) and this foreground desk-posture
    // check, which does.
    if (!movementEnabled && routePath(event.route ?? '') == kRouteMovement) {
      return false;
    }
    // The step-goal achievement's off switch — same route-keyed shape. (The
    // recovery-ready note needs no extra branch here: it rides the recovery
    // category, and categoryEnabled below already reads recoveryEnabled.)
    if (!stepGoalEnabled && routePath(event.route ?? '') == kRouteSteps) {
      return false;
    }
    final klass = classOf(event);
    if (klass == null) return false; // not one of the three — never fires
    // The alarm is the one thing quiet hours must not silence: the user armed
    // it FOR a time, usually inside the quiet window, and its off switch is
    // cancelling the alarm rather than a preference buried in settings.
    if (klass == NotifClass.alarm) return true;
    if (!categoryEnabled(event.category)) return false;
    if (inQuietHours(minuteOfDay)) {
      return event.priority == NotifPriority.critical && criticalOverridesQuiet;
    }
    return true;
  }
}

// Alias kept short for the gate signature above.
typedef NotifEvent = NotificationEvent;
