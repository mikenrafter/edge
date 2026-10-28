// notification_center.dart — the single emitter.
//
// Every insight and alert goes through emit(). OS-level notifications are the
// ONLY surface now — the in-app notifications feed/screen was removed (it
// duplicated the OS notification with no independent value).
//
// emit() is the PRESENT path. The standing schedules further down
// (scheduleStandingReminders, scheduleAiReminders) are the SCHEDULE path, which
// never passes through emit at all: the OS fires those with no Dart running.
// They are gated by NotificationService.schedulableIds instead.
//
// Whether an emitted event fires an OS notification is decided by
// NotificationPrefs:
//   • it must be one of the four sanctioned NotifClasses (see classOf), AND
//   • its category must be enabled, AND
//   • either we're outside quiet hours, or the event is critical and the user
//     allowed critical-overrides-quiet.
// The alarm is exempt from the last two: the user armed it for a time that is
// usually inside their own quiet window.
//
// Emit sites that are no longer one of the three (recovery-ready, step goal,
// posture, "did you work out?") still call emit() and are dropped HERE rather
// than at each site — one gate is how the rule stays true when the next emit
// site is added.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_prefs.dart';
import '../ai/reminder_plan.dart';
import '../data/day_label.dart';
import '../data/journal_fields.dart';
import '../data/med_store.dart';
import '../state/clock_format.dart' show formatClockMinute;
import '../data/water_units.dart';
import 'fired_keys.dart';
import 'reminder_sleep_gate.dart';
import 'alert_dispatcher.dart';
import 'notification_event.dart';
import 'notification_prefs.dart';
import 'notification_service.dart';
import '../state/feature_flags.dart';
import '../state/units_controller.dart' show UnitSystem, UnitsController;
import 'tap_router.dart';

class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter instance = NotificationCenter._();

  /// AppState installs the connected-band transport; headless callers still
  /// use this same dispatcher with the phone transport available.
  AlertDispatcher dispatcher = AlertDispatcher(
    phone: () async => false,
    band: () async => false,
    isConnected: () => false,
    ledger: const NotificationCenterDeliveryLedger(),
  );

  Future<bool> emit(
    NotificationEvent e, {
    bool allowPermissionPrompt = true,
    DateTime? sourceTime,
    bool historical = false,
    String? ruleId,
    bool phoneOnly = false,
  }) async {
    final prefs = await NotificationPrefs.load();
    final id =
        ruleId ??
        switch (routePath(e.route ?? '')) {
          kRouteMovement => 'movement',
          kRouteSteps => 'stepGoal',
          kRouteRecovery => 'recovery',
          kRouteWorkoutSuggestion || kRouteDetectedActivities =>
            Uri.tryParse(e.route ?? '')?.queryParameters['kind'] == 'nap'
                ? 'napDetect'
                : 'autoDetect',
          _ => classOf(e) == NotifClass.alarm ? 'alarm' : e.category.name,
        };
    final now = DateTime.now();
    if (const {'water', 'movement', 'windDown', 'checkIn'}.contains(id) &&
        (await ReminderSleepGate.load(now: now)).reasonAt(prefs, now) != null) {
      return false;
    }
    final minuteOfDay = now.hour * 60 + now.minute;
    final explicitAction = ruleId != null &&
        const {'zone', 'breath', 'tasker', 'wake', 'relay'}.contains(ruleId);
    // FeatureFlag.alertDispatcher OFF: the pre-dispatcher delivery. Phone only,
    // through the same fire-once claim; a rule that does not select the phone
    // (or is off) stays silent, so switching the flag off never adds a phone
    // alert the user did not choose. Band haptics are not reachable from here.
    await FeatureFlags.ensureLoaded();
    if (!FeatureFlags.isOn(FeatureFlag.alertDispatcher)) {
      final rule = prefs.alertRule(id);
      if (!rule.enabled || !rule.phoneSelected) return false;
      return _emitPhone(
        e,
        allowPermissionPrompt: allowPermissionPrompt,
        explicitAction: explicitAction,
      );
    }
    final out = await dispatcher.dispatch(
      prefs.alertRule(id),
      eventId: e.dedupeKey,
      sourceTime: sourceTime ?? DateTime.now(),
      historical: historical,
      targetAllowed: (_) => explicitAction
          ? !prefs.inQuietHours(minuteOfDay)
          : prefs.shouldFireOs(e, minuteOfDay),
      // Legacy derived reports may describe yesterday. Their receipt time
      // cannot authorize a time-sensitive band haptic.
      transportTargets: phoneOnly || e.date.compareTo(todayLabel()) < 0
          ? const {'phone'} : null,
      phoneTransport: () => _emitPhone(
        e,
        allowPermissionPrompt: allowPermissionPrompt,
        explicitAction: explicitAction,
      ),
    );
    return out.targets.contains('phone');
  }

  /// The persistent "already fired this dedupeKey" guard. See [FiredKeyStore].
  final FiredKeyStore _fired = const FiredKeyStore();

  /// Tail of a chained-Future lock that serialises the claim-present-release
  /// critical section in [emit]. It keeps two overlapping emits in THIS isolate
  /// from interleaving their presents — more likely now the UI-thread stress
  /// alert can race the background derive loop.
  ///
  /// It is not what enforces fire-once. This lock can only order emits WITHIN
  /// this isolate; derivation also runs in the WorkManager isolate, which it
  /// cannot see. Fire-once across both is enforced by the atomic
  /// [FiredKeyStore.claim] below — one SQLite INSERT OR IGNORE, one winner.
  Future<void> _lock = Future<void>.value();

  /// Run [action] after any in-flight critical section completes, exclusively.
  Future<void> _synchronized(Future<void> Function() action) async {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future; // installed synchronously — orders concurrent callers
    await prev;
    try {
      await action();
    } finally {
      done.complete();
    }
  }

  /// The OS presentation sink. Returns true when the event was actually shown
  /// (permission granted, no error). Overridable in tests to assert call counts
  /// without a device; defaults to the real service.
  @visibleForTesting
  Future<bool> Function(NotificationEvent e, {bool allowPermissionPrompt})
  presentSink = NotificationService.instance.presentEvent;

  /// Present to the OS (if allowed). Never throws.
  ///
  /// [allowPermissionPrompt]: Apple's notification docs document that
  /// authorization must be requested IN CONTEXT, from an active foreground
  /// scene — never from a background execution context (a headless
  /// BGTaskScheduler run or Dart background isolate has none to present
  /// from). Callers that know they're running headless (see
  /// background_sync.dart's checkSyncStaleness) MUST pass `false`, so a
  /// not-yet-decided permission is checked, not requested, and never gets
  /// permanently mis-cached as "denied" by a background attempt.
  ///
  /// Returns TRUE only when the event actually reached the OS. Callers that
  /// keep their own "already fired today" guard (see [emitOncePerDay]) MUST key
  /// it off this, never off the mere fact that emit was called: the event is
  /// dropped outright when [NotificationPrefs.shouldFireOs] says no (quiet
  /// hours, category muted) or when the OS present fails.
  Future<bool> _emitPhone(
    NotificationEvent e, {
    bool allowPermissionPrompt = true,
    bool explicitAction = false,
  }) async {
    var presented = false;
    try {
      final prefs = await NotificationPrefs.load();
      final now = DateTime.now();
      final minuteOfDay = now.hour * 60 + now.minute;
      if (explicitAction) {
        if (prefs.inQuietHours(minuteOfDay)) return false;
      } else if (!prefs.shouldFireOs(e, minuteOfDay)) {
        return false;
      }
      // Enforce the dedupeKey's "fires at most once" contract (issue #136).
      // The OS id only REPLACES a prior post of the same key — it still
      // re-alerts — and derivation re-runs on every BLE sync, so an insight
      // whose condition holds all day would otherwise buzz over and over. The
      // guard resets itself per new day via the date-prefixed keys.
      //
      // CLAIM, don't check. A check-then-record pair is not atomic: the two
      // derivation isolates can both read "not fired" before either records and
      // both alert. [FiredKeyStore.claim] decides ownership in ONE atomic
      // operation, so exactly one caller — in either isolate — ever proceeds.
      //
      // A claim we don't spend is given straight back: a permission-denied
      // no-op or a throwing present must NOT consume the key, or that insight
      // stays silent for the rest of the day. Release on every non-present path
      // (hence the finally), which restores the pre-existing
      // "record only after a real present" semantics.
      await _synchronized(() async {
        if (!await _fired.claim(e.dedupeKey)) return;
        var shown = false;
        try {
          shown = await presentSink(
            e,
            allowPermissionPrompt: allowPermissionPrompt,
          );
        } finally {
          if (!shown) await _fired.release(e.dedupeKey);
        }
        presented = shown;
      });
    } catch (_) {
      /* OS present best-effort */
    }
    return presented;
  }

  /// Fire [e] at most once per [dayId], with the persisted day-guard at
  /// [prefsKey] consumed ONLY when the notification was actually presented.
  /// Returns true iff it fired.
  ///
  /// The callers of this (recovery-ready, step-goal) used to write the guard
  /// FIRST and then emit. [emit] drops the event outright when
  /// [NotificationPrefs.shouldFireOs] is false, so a band that syncs at 06:40 —
  /// inside the DEFAULT 22:00–07:00 quiet window — computed the new day's
  /// recovery, burned the guard, got suppressed, and then had every retry that
  /// day blocked by the guard it never earned: "Your recovery is ready" simply
  /// never fired. Claiming the guard only on a real present makes the retry
  /// (the next derive pass, after 07:00) work.
  ///
  /// That fix left the other half open: [dayId] is the day the DATA is from,
  /// and a suppressed event deliberately leaves the guard unspent, so the
  /// caller re-reads the SAME last row on every later foreground open. Deny
  /// notifications, walk 12k steps, leave the band in a drawer for a week, then
  /// turn notifications back on: "step goal reached" fired about a day the user
  /// wore nothing. Yesterday's news is not news — a past day never fires, and
  /// that gate belongs here, not in each caller.
  Future<bool> emitOncePerDay({
    required String prefsKey,
    required String dayId,
    required NotificationEvent e,
    bool allowPermissionPrompt = true,
  }) async {
    if (dayId.compareTo(todayLabel()) < 0) return false;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // no store — [emit]'s own FiredKeyStore still dedupes
    }
    if (prefs != null && prefs.getString(prefsKey) == dayId) return false;
    final shown = await emit(e, allowPermissionPrompt: allowPermissionPrompt);
    if (shown && prefs != null) {
      try {
        await prefs.setString(prefsKey, dayId);
      } catch (_) {
        /* guard is an optimisation; FiredKeyStore is the truth */
      }
    }
    return shown;
  }

  static const int recapWeekday = DateTime.sunday;
  static const int recapHour = 18; // Sunday 18:00
  static const int recapMinute = 0;

  /// Bring the OS scheduler in line with the user's prefs.
  ///
  /// This used to arm a wind-down nudge and an UNCONDITIONAL weekly recap on
  /// every foreground resume. What is armed now is only what the user asked for
  /// by name: the weekly lookback for a week that actually contained something
  /// ([weeklyFinding] is the whole condition — null means it isn't armed), and
  /// the hydration slots while the water reminder is on.
  ///
  /// The cancels are not conditional and must stay that way: they are what
  /// clears whatever an older build — or the user's own switch, a moment ago —
  /// left standing. They also run BEFORE the permission check, deliberately —
  /// see the note in [_armWeeklyLookback] for why the check moved down there.
  ///
  /// [bedtimeMinOfDay] is no longer read: it timed the wind-down nudge. Kept so
  /// the existing caller compiles unchanged; drop both together.
  /// [checkInDoneToday] — whether the day's self-report is already written
  /// (see [checkInDone]). The prompt is not armed for a day that is already
  /// answered, which is the whole reason the caller reads it. NULL means the
  /// caller could not tell, and the check-in is then left exactly as it is.
  ///
  /// [medDefs] / [medDosesToday] come straight from `MedDb` and are only read
  /// when `prefs.medsEnabled` is on. NULL means the caller did not read the
  /// schedule at all — the notifications screen re-asserting after an
  /// unrelated toggle, or a read that threw — and the armed doses are then
  /// left exactly as they are. An EMPTY list is an answer: there are no
  /// medications, and the old slots go. They stay parameters rather than a query
  /// in here for the same reason [weeklyFinding] does: this method is the
  /// policy, and a policy that opens the database cannot be tested without
  /// one.
  ///
  /// [armedTonight]: whether the REAL armed alarm (AppState.alarmEpoch, not
  /// merely an enabled schedule row) falls on today's calendar date — see
  /// [alarmNightCheckSlot]. Always a real answer (never null): unlike
  /// `checkInDoneToday`/`medDefs`, it costs no extra read (AppState already
  /// holds the armed epoch), so there is no "caller doesn't know" case to
  /// preserve through.
  /// Public entry point — serialized through [_synchronized] so two
  /// overlapping callers (e.g. a foreground resume racing a sync-completion
  /// callback) can't interleave their cancel/re-arm passes and have a stale
  /// call clobber a newer one's result.
  Future<void> scheduleStandingReminders(
    NotificationPrefs prefs, {
    double? bedtimeMinOfDay,
    String? weeklyFinding,
    bool? checkInDoneToday,
    List<MedDef>? medDefs,
    Map<String, Map<int, Map<String, Object?>>> medDosesToday = const {},
    bool armedTonight = false,
    ReminderSleepGate? sleep,
  }) => _synchronized(
    () => _scheduleStandingReminders(
      prefs,
      bedtimeMinOfDay: bedtimeMinOfDay,
      weeklyFinding: weeklyFinding,
      checkInDoneToday: checkInDoneToday,
      medDefs: medDefs,
      medDosesToday: medDosesToday,
      armedTonight: armedTonight,
      sleep: sleep,
    ),
  );

  Future<void> _scheduleStandingReminders(
    NotificationPrefs prefs, {
    double? bedtimeMinOfDay,
    String? weeklyFinding,
    bool? checkInDoneToday,
    List<MedDef>? medDefs,
    Map<String, Map<int, Map<String, Object?>>> medDosesToday = const {},
    bool armedTonight = false,
    ReminderSleepGate? sleep,
  }) async {
    final gate = sleep ?? await ReminderSleepGate.load(now: DateTime.now());
    final svc = NotificationService.instance;
    await svc.cancel(NotificationService.idWeeklyRecap);
    // The night-check is decided fresh on every call (armedTonight is always a
    // real answer, unlike checkInDoneToday) — cancel unconditionally, then
    // re-arm below exactly like the weekly recap just above.
    await svc.cancel(NotificationService.idAlarmNightCheck);
    // Wind-down follows the standing rule — cancel what this call cannot put
    // back, and only that. A null slot (switch off, or no LEARNED bedtime yet)
    // cancels; a real slot is armed below.
    final windDownMin = windDownSlot(prefs, bedtimeMinOfDay, sleep: gate);
    if (windDownMin == null || !prefs.phoneDeliveryEnabled('windDown')) {
      await svc.cancel(NotificationService.idWindDown);
    }
    // The check-in and the medication band follow the same rule as the
    // movement nudge below: cancel what the user just switched off, and
    // otherwise only what THIS call can put back.
    //
    // `checkInDoneToday` null means the caller does not know whether today is
    // already written — the notifications screen re-asserting after an
    // unrelated toggle. Cancelling then would drop tonight's prompt, and
    // re-arming would risk asking for a day already answered, so neither
    // happens and the next foreground pass (which does know) decides.
    final pendingCheckIn = checkInSlot(prefs, bedtimeMinOfDay,
        doneToday: false, now: DateTime.now());
    final checkInProtected = pendingCheckIn != null &&
        gate.reasonAt(prefs, pendingCheckIn) != null;
    if (!prefs.phoneDeliveryEnabled('checkIn') || checkInDoneToday != null || checkInProtected) {
      await svc.cancel(NotificationService.idCheckIn);
    }
    // The medication band is cancelled when the switch is OFF — that is where
    // a reminder the user just turned off actually goes away — or when we were
    // handed the schedule and can therefore re-arm from it a few lines down.
    //
    // NOT unconditionally. This method also runs from the notifications screen
    // after any unrelated toggle, with no schedule passed, and an unconditional
    // cancel there would bin every armed dose for a user who came in to change
    // their quiet hours. Cancel only what this call can put back.
    //
    // NULL, NOT EMPTY, is what "no schedule passed" means — and that is the
    // whole distinction. "There are no medications" and "the medication table
    // could not be read" are different facts with opposite correct answers:
    // an EMPTY schedule must cancel, or a user who deleted their last
    // medication keeps getting reminded to take it, forever, because nothing
    // else ever cancels these. An UNAVAILABLE one must preserve, because
    // re-arming is impossible and cancelling would silently disarm doses that
    // are still real. Collapsing both into `const []` chose preserve for both,
    // so the deleted-medication case never got its cancel.
    if (!prefs.phoneDeliveryEnabled('meds') || medDefs != null) {
      for (var i = 0; i < NotificationService.maxMedSlots; i++) {
        await svc.cancel(NotificationService.idMedsBase + i);
      }
    }
    // idStillness is NOT a standing schedule and must not be cancelled with
    // them. It is a one-shot armed by live movement
    // (`AppState._rescheduleStillnessNudge`), nothing in this method re-arms
    // it, and this method runs on EVERY foreground resume — so the fix for
    // issue #123 was cancelling itself: open the app and the nudge was binned.
    // The re-arm needs a connected band streaming foreground IMU AND is
    // throttled to once per ten minutes, so it is not a gap that closes on its
    // own; with the band off the wrist it never closes at all.
    //
    // The one cancel that IS correct here is the user's own switch: this is
    // where a movement nudge that was just turned off actually goes away.
    if (!prefs.phoneDeliveryEnabled('movement') ||
        gate.reasonAt(prefs, DateTime.now()) != null) {
      await svc.cancel(NotificationService.idStillness);
    }
    for (var i = 0; i < NotificationService.maxWaterSlots; i++) {
      await svc.cancel(NotificationService.idWaterBase + i);
    }
    final water = prefs.phoneDeliveryEnabled('water')
        ? waterSlotMinutes(prefs, sleep: gate)
        : <int>[];
    final wantWeekly =
        prefs.phoneDeliveryEnabled('reminders') && weeklyFinding != null;
    final now = DateTime.now();
    final checkIn = checkInDoneToday == null
        ? null
        : checkInSlot(
            prefs,
            bedtimeMinOfDay,
            doneToday: checkInDoneToday,
            now: now,
            sleep: gate,
          );
    final meds = medPromptSlots(
      prefs,
      medDefs ?? const [],
      medDosesToday,
      now: now,
    );
    final nightCheck = alarmNightCheckSlot(
      prefs,
      armedTonight: armedTonight,
      nowMin: now.hour * 60 + now.minute,
    );
    if (water.isEmpty &&
        !wantWeekly &&
        windDownMin == null &&
        checkIn == null &&
        meds.isEmpty &&
        nightCheck == null) {
      return;
    }
    // Re-resolve the zone first: this runs on every foreground resume, and the
    // instants below are wall-clock. A phone that flew somewhere would otherwise
    // keep arming Sunday 18:00 in the zone the app first launched in.
    await svc.ensureTimezone();
    await _armWaterSlots(svc, water, prefs, gate);
    if (wantWeekly && gate.reasonAt(prefs, svc.nextWeeklyInstant(recapWeekday, recapHour, recapMinute)) == null) await _armWeeklyLookback(svc, weeklyFinding);
    if (windDownMin != null && prefs.phoneDeliveryEnabled('windDown')) {
      await _armWindDown(svc, windDownMin, bedtimeMinOfDay!);
    }
    if (checkIn != null && prefs.phoneDeliveryEnabled('checkIn')) {
      await _armCheckIn(svc, checkIn);
    }
    if (prefs.phoneDeliveryEnabled('meds')) await _armMedSlots(svc, meds);
    // Recomputed fresh right before arming, not reused from the `now` this
    // call started with — the awaits above (zone resolve + every slot ahead
    // of this one) are real wall-clock time, and this is the one slot whose
    // hour boundary (19:00) a stale `nowMin` could cross mid-call.
    final freshNow = DateTime.now();
    final freshNightCheck = alarmNightCheckSlot(
      prefs,
      armedTonight: armedTonight,
      nowMin: freshNow.hour * 60 + freshNow.minute,
    );
    if (freshNightCheck != null &&
        prefs.phoneDeliveryEnabled('alarmNightCheck') &&
        gate.reasonAt(prefs, svc.nextDailyInstant(alarmNightCheckHour, 0)) == null) {
      await _armAlarmNightCheck(svc, freshNightCheck);
    }
  }

  /// Runs [action] exclusively with every other scheduling pass (the standing
  /// reminders, the AI reminders): a complete read, validate, cancel and arm
  /// sequence cannot interleave with another one, so a stale plan is never
  /// armed after a newer one cancelled it. Not reentrant: [action] must not
  /// call another locked method.
  Future<void> runScheduling(Future<void> Function() action) =>
      _synchronized(action);

  /// The phone backstop of a main-alarm snooze: one OS-scheduled notification
  /// at the snooze's [due] time. A suspended phone cannot run the snooze's
  /// timer, but the OS posts this on time; if the app is awake the re-alarm
  /// plays as well. Calling again replaces the pending one. Quiet hours do not
  /// apply (it is the user's own alarm, like the alarm itself); the OS posts a
  /// scheduled slot with no Dart running, so it never passes
  /// [NotificationPrefs.shouldFireOs]. Never throws.
  Future<void> armSnoozeBackstop(DateTime due) async {
    try {
      await NotificationService.instance.scheduleOnce(
        id: NotificationService.idSnoozeBackstop,
        category: NotifCategory.reminders,
        title: 'Wake alarm',
        body: 'Your snooze is over. Time to get up.',
        at: due,
        route: kRouteAlarm,
        exact: true,
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// Cancels [armSnoozeBackstop]'s notification (the snooze ended). Never
  /// throws.
  Future<void> cancelSnoozeBackstop() async {
    try {
      await NotificationService.instance
          .cancel(NotificationService.idSnoozeBackstop);
    } catch (_) {
      /* best-effort */
    }
  }

  /// The hour the 7pm no-alarm-tonight check-in fires at, when armed.
  static const int alarmNightCheckHour = 19;

  /// The check-in's wall-clock minute, or null when it must not be armed: the
  /// toggle is off, an alarm IS armed for tonight (the honest gate — the whole
  /// point is to catch the GAP, not to nag someone who already has one set),
  /// or 19:00 has already passed today (a one-shot rolled to tomorrow would
  /// warn about TONIGHT a day late). No quiet-hours cap like windDown/checkIn:
  /// 19:00 is fixed and outside the default quiet window, and moving it to
  /// dodge a user-configured quiet window would just make the warning late.
  static int? alarmNightCheckSlot(
    NotificationPrefs prefs, {
    required bool armedTonight,
    required int nowMin,
  }) {
    if (!prefs.alarmNightCheckEnabled || armedTonight) return null;
    final t = alarmNightCheckHour * 60;
    if (nowMin >= t) return null;
    return t;
  }

  /// The 7pm one-shot itself. ONE-SHOT, not a daily repeat, for the same
  /// reason the check-in and med slots are: "armed for tonight" is a fact
  /// about today specifically, and a repeat would go on warning about a night
  /// that, by the next evening, may well have a real alarm set.
  Future<void> _armAlarmNightCheck(
    NotificationService svc,
    int minuteOfDay,
  ) async {
    await svc.scheduleOnce(
      id: NotificationService.idAlarmNightCheck,
      category: NotifCategory.reminders,
      title: 'No alarm set for tonight',
      body: 'The band will not wake you tomorrow.',
      at: svc.nextDailyInstant(minuteOfDay ~/ 60, minuteOfDay % 60),
      route: kRouteAlarm,
    );
  }

  /// One notification per dose still due — never one per day, never a summary.
  ///
  /// ONE-SHOT per slot, at the minute the user entered. A daily repeat cannot
  /// know whether today's dose was already taken, and a reminder for a pill
  /// already swallowed is exactly the notification people turn everything off
  /// over. The cost of the one-shot is that cover only reaches as far as
  /// [medPromptSlots]' horizon from the last foreground pass; the reminder
  /// re-arms on every resume, which for anyone who opens the app daily is
  /// always ahead of the doses.
  ///
  /// Quiet hours are deliberately NOT applied: this is the user's own entered
  /// time, the same reasoning that exempts the alarm. Someone who takes a pill
  /// at 23:00 typed 23:00.
  Future<void> _armMedSlots(
    NotificationService svc,
    List<MedSlot> slots,
  ) async {
    for (var i = 0; i < slots.length; i++) {
      final s = slots[i];
      final at = medSlotInstant(s);
      if (at == null) continue;
      await svc.scheduleOnce(
        id: NotificationService.idMedsBase + i,
        category: NotifCategory.reminders,
        // NO MEDICATION NAME, deliberately. This lands on a lock screen, in
        // front of whoever is in the room, and "which drug" is the most
        // sensitive fact in the app. The checklist behind the tap says which —
        // one unlock away, which is where that belongs. It is also why the
        // body is not a dose or a count.
        title: 'Medication',
        // Not an adherence score, not a streak, and nothing about a dose that
        // was missed: this is the reminder, not the report.
        body: 'A dose is due.',
        at: at,
        route: kRouteMeds,
      );
    }
  }

  /// The daily check-in, as a ONE-SHOT at [at] (see [checkInSlot]).
  ///
  /// One-shot for the same reason the meds slots are: whether the day is
  /// already written changes daily, and a repeat would go on asking after the
  /// journal was filled in. Re-armed on every foreground pass, and once the day
  /// has any rating in it the caller moves it to tomorrow.
  Future<void> _armCheckIn(NotificationService svc, DateTime at) async {
    await svc.scheduleOnce(
      id: NotificationService.idCheckIn,
      category: NotifCategory.reminders,
      title: 'How was today?',
      // No guilt, no count, no reference to a day that was missed.
      body: 'Log mood, energy and stress.',
      at: at,
      route: kRouteJournalCompose,
    );
  }

  /// Upcoming one-shots fit the OS id band. Refresh cancels and replaces them
  /// when new sleep becomes known; an old repeat must not outlive that evidence.
  ///
  /// The strap buzz (WaterBuzzer) fires off the SAME [slots] list, so the two
  /// land at the same wall-clock minute — but the buzz needs a live BLE link
  /// and a live isolate, and a reminder that only arrives when the app happens
  /// to be running is not a reminder. Both fire. There is deliberately no
  /// "only notify if the strap didn't buzz" preference: nobody has felt the
  /// double yet.
  ///
  /// Copy rule: this may nudge you to LOG a drink and nothing more. The app
  /// measures no hydration, scores none, and this text may never imply either.
  Future<void> _armWaterSlots(
    NotificationService svc,
    List<int> slots,
    NotificationPrefs prefs,
    ReminderSleepGate sleep,
  ) async {
    UnitSystem system;
    try {
      system = await UnitsController.savedSystem();
    } catch (_) {
      system = UnitSystem.metric; // no preference store (a headless run)
    }
    final body = waterReminderBody(prefs, system: system);
    final upcoming = [for (final minute in slots)
      svc.nextDailyInstant(minute ~/ 60, minute % 60)]
      ..sort((a, b) => a.compareTo(b));
    var i = 0;
    for (final at in upcoming) {
      if (sleep.reasonAt(prefs, at) != null) continue;
      if (i >= NotificationService.maxWaterSlots) break;
      await svc.scheduleOnce(
        id: NotificationService.idWaterBase + i++,
        category: NotifCategory.reminders,
        title: 'Water',
        body: body,
        at: at,
        route: kRouteWater,
      );
    }
  }

  /// One upcoming wind-down slot, refreshed with sleep eligibility.
  ///
  /// A later sleep observation can cancel this occurrence. Refresh replaces
  /// the same id, so rescheduling never stacks wind-down notifications.
  Future<void> _armWindDown(
    NotificationService svc,
    int minuteOfDay,
    double bedtimeMinOfDay,
  ) async {
    await svc.scheduleOnce(
      id: NotificationService.idWindDown,
      category: NotifCategory.reminders,
      title: 'Wind down',
      body: windDownBody(bedtimeMinOfDay),
      at: svc.nextDailyInstant(minuteOfDay ~/ 60, minuteOfDay % 60),
      route: kRouteBreathing,
    );
  }

  /// The wind-down copy. Names the LEARNED bedtime, not the slot plus the
  /// offset: quiet hours can pull the slot earlier.
  static String windDownBody(double bedtimeMinOfDay) =>
      'Your bedtime is around ${_hhmm(bedtimeMinOfDay.round())}. '
      'Start slowing down.';

  /// How long before the learned bedtime the wind-down lands.
  static const int windDownBeforeBedMin = 45;

  /// How far inside the quiet window's edge the slot must stay clear of.
  static const int _windDownQuietMarginMin = 30;

  /// The wind-down's wall-clock minute, or null when it must not be armed.
  ///
  /// Requires BOTH the switch and a LEARNED bedtime ([bedtimeMinOfDay] from
  /// the Sleep Coach). A population fallback here would be a made-up time
  /// pretending to know this user's sleep — if the coach hasn't learned a
  /// bedtime yet, the nudge waits. (The check-in may fall back to a stated
  /// fixed time because its copy says "evening"; this one's whole content IS
  /// the time, so there is nothing honest to fall back to.)
  ///
  /// The offset wraps across midnight: a learned bedtime of 00:20 wants its
  /// wind-down at 23:35 the SAME evening, which `scheduleDaily`'s
  /// next-occurrence arithmetic delivers from a 23:35 minutes-of-day value.
  ///
  /// OS-scheduled notifications fire with no Dart running, so
  /// [NotificationPrefs.shouldFireOs] never sees one — quiet hours must be
  /// applied HERE. Same shape as the check-in: cap to half an hour before
  /// quiet opens, and refuse outright if the slot would still land inside
  /// the protected window.
  static int? windDownSlot(NotificationPrefs prefs, double? bedtimeMinOfDay,
      {ReminderSleepGate? sleep}) {
    if (!prefs.windDownEnabled || bedtimeMinOfDay == null) return null;
    // Wrap across midnight, staying non-negative (Dart % can go negative for
    // negative operands only when the modulus is... it cannot here — but the
    // +1440 makes the intent explicit and survives sign changes).
    var t =
        ((bedtimeMinOfDay.round() - windDownBeforeBedMin) % 1440 + 1440) % 1440;
    if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
      final cap = prefs.quietStartMin - _windDownQuietMarginMin;
      if (t > cap) t = cap;
    }
    if (prefs.inQuietHours(t)) return null;
    if (sleep != null) {
      final now = DateTime.now();
      var target = DateTime(now.year, now.month, now.day, t ~/ 60, t % 60);
      if (!target.isAfter(now)) target = DateTime(now.year, now.month, now.day + 1, t ~/ 60, t % 60);
      if (sleep.reasonAt(prefs, target) != null) return null;
    }
    return t;
  }

  /// Minutes-past-midnight → the user's clock format (notification bodies).
  static String _hhmm(int minuteOfDay) => formatClockMinute(minuteOfDay);

  // ── the weekly lookback finding ─────────────────────────────────────────

  /// What Sunday's lookback says, or null when the week was quiet enough that
  /// NOTHING should interrupt the user. PURE over the crossday rollup's
  /// `recent[]` rows ({date, rhr, unsettled, illness, anomaly, temp}).
  ///
  /// The bar is deliberately high: most weeks must produce null. A weekly
  /// notification that fires every Sunday is the recap problem all over again
  /// — the reason the slot sat unwired for so long was that nothing honest
  /// could fill it. Priority: medical flags first (they are the sanctioned
  /// detections), then a plainly-stated resting-HR drift, then silence.
  static String? weeklyLookbackFinding(List<Map<String, dynamic>> recentDays) {
    // `recent[]` is the whole rollup window (90 days, oldest first); the
    // lookback is the last week of it.
    // ponytail: last 7 rows, not 7 calendar days; a gappy week reaches a bit
    // further back.
    final week = recentDays.length > 7
        ? recentDays.sublist(recentDays.length - 7)
        : recentDays;
    final days = week
        .where((d) => d['unsettled'] != true)
        .toList(growable: false);
    if (days.isEmpty) return null;

    // Medical flags, counted per kind. These reuse the same detectors the
    // daily health exception fires on — the weekly note only SUMMARIZES them.
    final illness = days.where((d) => d['illness'] == true).length;
    final anomaly = days.where((d) => d['anomaly'] == true).length;
    final temp = days.where((d) => d['temp'] == true).length;
    final parts = <String>[];
    if (illness > 0) parts.add('resting heart rate raised ×$illness');
    if (anomaly > 0) parts.add('unusual physiology ×$anomaly');
    if (temp > 0) parts.add('elevated skin temperature ×$temp');
    if (parts.isNotEmpty) {
      return 'This week flagged: ${parts.join(', ')}. See Health for details.';
    }

    // Resting-HR drift across the week: mean of the last three nights vs the
    // first three. Plain arithmetic on stored nightly values, stated as such
    // — no trend test dressed up as science. Needs ≥5 settled nights with an
    // RHR on both ends, which is also what keeps this silent most weeks.
    final rhrs = [
      for (final d in days)
        if (d['rhr'] is num) (d['rhr'] as num).toDouble(),
    ];
    if (rhrs.length >= 5) {
      double mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
      final early = mean(rhrs.sublist(0, 3));
      final late = mean(rhrs.sublist(rhrs.length - 3));
      final delta = late - early;
      if (delta >= 3) {
        return 'Resting heart rate ran about ${delta.round()} bpm higher '
            'late in the week than early.';
      }
      if (delta <= -3) {
        return 'Resting heart rate ran about ${(-delta).round()} bpm lower '
            'late in the week than early.';
      }
    }
    return null;
  }

  Future<void> _armWeeklyLookback(
    NotificationService svc,
    String finding,
  ) async {
    await svc.scheduleOnce(
      id: NotificationService.idWeeklyRecap,
      category: NotifCategory.reminders,
      title: 'Your week in review',
      body: finding,
      at: svc.nextWeeklyInstant(recapWeekday, recapHour, recapMinute),
      // A week of sleep, strain and recovery lives on Health.
      route: kRouteRecap,
    );
  }

  /// The body of the water reminder: names one glass in the user's units (the
  /// shared WaterUnits formatter) and, when [prefs] assumes a glass per slot,
  /// says plainly that it was assumed. A nudge to LOG a drink and nothing more.
  static String waterReminderBody(
    NotificationPrefs prefs, {
    required UnitSystem system,
  }) {
    final glass =
        WaterUnits.format(WaterUnits.stepMl(system), system);
    // Never a goal, a score or a "behind": the app measures no hydration.
    return prefs.waterAssumeDrank
        ? 'A glass ($glass) was assumed. Tap to review.'
        : 'Tap to log a glass ($glass).';
  }

  // Cadence anchor retained for same-day quiet windows. With quiet hours off,
  // the full local day is available and sleep evidence filters each slot.
  static const int _waterDayStartMin = 8 * 60; // 08:00
  static const int _waterDayEndMin = 22 * 60; // 22:00

  /// Recurring water slots after quiet hours and expected sleep filtering.
  /// Detected periods require an actual date; the OS scheduler checks each
  /// upcoming instant separately. Filtering never shifts the cadence.
  static List<int> waterSlotMinutes(NotificationPrefs prefs,
      {ReminderSleepGate? sleep, DateTime? day}) {
    final d = (day ?? DateTime.now()).toLocal();
    final gate = day == null ? ReminderSleepGate(schedule: sleep?.schedule) : sleep ?? const ReminderSleepGate();
    return [for (final m in waterCadenceMinutes(prefs))
      if (gate.reasonAt(prefs, DateTime(d.year, d.month, d.day, m ~/ 60, m % 60)) == null) m];
  }

  static List<int> waterCadenceMinutes(NotificationPrefs prefs) {
    if (!prefs.waterEnabled) return const [];
    final interval = prefs.waterIntervalMin.clamp(
      NotificationPrefs.waterIntervalMinAllowed, NotificationPrefs.waterIntervalMaxAllowed);
    var startMin = prefs.quietEnabled ? _waterDayStartMin : 0;
    var endMin = prefs.quietEnabled ? _waterDayEndMin : 1440;
    if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
      startMin = prefs.quietEndMin;
      endMin = prefs.quietStartMin;
    }
    if (endMin - startMin < interval) {
      startMin = (startMin + endMin) ~/ 2;
      endMin = startMin + 1;
    }
    return [for (var t = startMin; t < endMin; t += interval) t];
  }

  // ── the daily check-in ──────────────────────────────────────────────────
  //
  // ONE prompt for the whole self-report, not one per field. Mood, energy,
  // stress, soreness and sleep quality are all written on the same screen, so
  // five prompts would be five interruptions for one minute of typing.

  /// Fixed fallback time when nothing has learned a bedtime yet: 20:30. Late
  /// enough that the day is over, early enough to be well clear of the default
  /// quiet window.
  static const int checkInFallbackMin = 20 * 60 + 30;

  /// How long before the recommended bedtime the check-in lands.
  static const int checkInBeforeBedMin = 60;

  /// Never before this — a "how was today?" at teatime is asking about a day
  /// that has not happened.
  static const int checkInEarliestMin = 17 * 60;

  /// Whether the day's self-report is already written, from
  /// `journal_metric` for that day.
  ///
  /// RATINGS only. Water and caffeine are logged as they happen and say
  /// nothing about whether the day has been reflected on; mood, energy, stress,
  /// soreness and sleep quality are the answer the prompt is asking for. A
  /// single one of them is enough — the screen is one screen, and someone who
  /// filled in mood and stopped has been asked.
  static bool checkInDone(Map<String, JournalMetricValue> todayMetrics) {
    for (final f in kJournalFields) {
      if (f.isRating && todayMetrics.containsKey(f.key)) return true;
    }
    return false;
  }

  /// The check-in's wall-clock minute, or null when it must not be armed.
  ///
  /// TIMED OFF THE PERSON where the data supports it: an hour before the
  /// bedtime the Sleep Coach learned from their own nights, so a late
  /// chronotype is not asked about their day at what is, for them, mid-evening.
  /// [bedtimeMinOfDay] null (no recommendation yet) falls back to a fixed
  /// [checkInFallbackMin], stated rather than pretended.
  ///
  /// The window is then bounded on both sides. Quiet hours do not gate an OS
  /// schedule — the OS fires it with no Dart running — so the ceiling is
  /// applied HERE instead: half an hour before the quiet window opens, and
  /// never after it. A 01:00 bedtime must not produce a midnight prompt.
  static int? checkInMinute(NotificationPrefs prefs, double? bedtimeMinOfDay) {
    if (!prefs.checkInEnabled) return null;
    var t = bedtimeMinOfDay == null
        ? checkInFallbackMin
        : bedtimeMinOfDay.round() - checkInBeforeBedMin;
    if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
      final cap = prefs.quietStartMin - 30;
      if (t > cap) t = cap;
    }
    if (t < checkInEarliestMin) t = checkInEarliestMin;
    // A degenerate quiet window (one that swallows the whole evening) leaves
    // nowhere honest to put this. Nothing is armed rather than something at
    // a time the user has already said not to interrupt.
    if (prefs.inQuietHours(t) || t >= 24 * 60) return null;
    return t;
  }

  /// [checkInMinute] as the instant to arm, with the "already answered" rule
  /// applied.
  ///
  /// Today's instance only while it is still ahead and today is unwritten;
  /// otherwise tomorrow's. A day written at 19:00 for a 20:30 slot skips
  /// tonight but still arms tomorrow — the prompt is re-armed on every
  /// foreground pass, but a user who does not open the app tomorrow would
  /// otherwise never be asked again.
  static DateTime? checkInSlot(
    NotificationPrefs prefs,
    double? bedtimeMinOfDay, {
    required bool doneToday,
    required DateTime now,
    ReminderSleepGate? sleep,
  }) {
    final t = checkInMinute(prefs, bedtimeMinOfDay);
    if (t == null) return null;
    final today = !doneToday && t > now.hour * 60 + now.minute;
    final target = DateTime(
        now.year, now.month, now.day + (today ? 0 : 1), t ~/ 60, t % 60);
    if (sleep?.reasonAt(prefs, target) != null) return null;
    return target;
  }

  /// When the "time to move" one-shot fires for movement seen at [now]: two
  /// hours on, or null when that lands outside the day or inside quiet hours.
  /// The OS fires it with no Dart running, so [NotificationPrefs.shouldFireOs]
  /// never sees it — quiet hours are applied here, as for [windDownSlot].
  static DateTime? stillnessNudgeAt(NotificationPrefs prefs, DateTime now,
      {ReminderSleepGate? sleep}) {
    final at = now.add(const Duration(hours: 2));
    if (at.hour < 9 || at.hour >= 21) return null; // outside daytime
    if ((sleep ?? const ReminderSleepGate()).reasonAt(prefs, at) != null) return null;
    return at;
  }

  // ── medication ──────────────────────────────────────────────────────────

  /// How far ahead doses are armed. Three days rather than one because these
  /// are one-shots: nothing re-arms them while the app is closed, and a
  /// weekend without opening the app should not silently drop a prescription.
  /// Not more, because a slot armed days out cannot know it was taken early.
  static const int medHorizonDays = 3;

  /// The doses to arm: every slot still UPCOMING across [medHorizonDays],
  /// soonest first, capped at [NotificationService.maxMedSlots].
  ///
  /// `DoseState.upcoming` is the whole rule-4 answer and it is already
  /// computed by [slotsForDay]: a dose marked taken, a dose deliberately
  /// skipped, and a slot that has already passed are all something other than
  /// upcoming, and none of them is armed. [dosesToday] only covers today
  /// because that is the only day a dose can already have been recorded for.
  static List<MedSlot> medPromptSlots(
    NotificationPrefs prefs,
    List<MedDef> defs,
    Map<String, Map<int, Map<String, Object?>>> dosesToday, {
    DateTime? now,
  }) {
    if (!prefs.medsEnabled || defs.isEmpty) return const [];
    final at = now ?? DateTime.now();
    final out = <MedSlot>[];
    for (var d = 0; d < medHorizonDays; d++) {
      final day = dayLabelOf(DateTime(at.year, at.month, at.day + d));
      for (final s in slotsForDay(
        defs,
        day,
        d == 0 ? dosesToday : const {},
        now: at,
      )) {
        if (s.state != DoseState.upcoming) continue;
        // Two pills at 08:00 are ONE interruption. The list is in time order,
        // so an instant equal to the last kept one is the same moment — and
        // the notification names nothing anyway, so a second copy of it would
        // carry no extra information and burn an id from the band.
        if (out.isNotEmpty &&
            out.last.date == s.date &&
            out.last.slotMin == s.slotMin) {
          continue;
        }
        out.add(s);
        if (out.length >= NotificationService.maxMedSlots) return out;
      }
    }
    return out;
  }

  /// The absolute instant [s] is due, or null when its day cannot be resolved.
  ///
  /// Built as a calendar `DateTime(y, m, d, hour, minute)`, not
  /// `localDayStartSec + slotMin*60` — the latter treats every day as a
  /// uniform 86400s of elapsed time, which is wrong on a DST transition day
  /// (see `day_label.dart`'s `localDayEndSec` for the same class of bug).
  static DateTime? medSlotInstant(MedSlot s) {
    final parts = s.date.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d, 0, s.slotMin);
  }

  /// Re-assert the three AI slots (morning briefing, nightly sweep, pre-sleep
  /// journal prompt).
  ///
  /// Only the nightly sweep is armed. It earns the interruption the same way
  /// the weekly lookback does — [sweepHeadline] is a finding that already
  /// exists, computed on-device before this is called, and it IS the
  /// notification's body. The morning briefing and the journal prompt are
  /// still nudges with no finding behind them; [aiReminderPlan] still describes
  /// them (it is the plan, not the policy) and
  /// [NotificationService.maySchedule] still refuses them, quietly, right here.
  ///
  /// The cancels stay unconditional: they are what clears yesterday's slot when
  /// today has nothing to say, and what clears whatever an older build left.
  Future<void> scheduleAiReminders(
    NotificationPrefs prefs,
    AiPrefs ai, {
    required bool aiConfigured,
    double? bedtimeMinOfDay,
    required bool journalDoneToday,
    String? sweepHeadline,
    ReminderSleepGate? sleep,
  }) async {
    final gate = sleep ?? await ReminderSleepGate.load(now: DateTime.now());
    final svc = NotificationService.instance;
    await svc.cancel(NotificationService.idMorningBrief);
    await svc.cancel(NotificationService.idEveningBrief);
    await svc.cancel(NotificationService.idJournalLog);
    final plan = aiReminderPlan(
      ai,
      remindersEnabled: prefs.remindersEnabled,
      aiConfigured: aiConfigured,
      bedtimeMinOfDay: bedtimeMinOfDay,
      journalDoneToday: journalDoneToday,
      sweepHeadline: sweepHeadline,
      quiet: prefs,
    ).where((s) => NotificationService.maySchedule(s.id)).toList();
    if (plan.isEmpty) return;
    await svc.ensureTimezone();
    final nowMin = DateTime.now().hour * 60 + DateTime.now().minute;
    for (final s in plan) {
      // ONE-SHOT, and only when the slot is still ahead TODAY.
      //
      // Both halves matter and both are the same bug the weekly lookback
      // already carries a comment about. A daily REPEAT would re-announce
      // tonight's finding every night for the life of the install, because the
      // body is a fact about one specific day. And a one-shot that rolled over
      // to tomorrow would announce today's finding about a day it did not
      // happen on. Nothing is armed instead — this re-runs on the next
      // foreground pass, which is where the finding is recomputed anyway.
      if (s.hour * 60 + s.minute <= nowMin) continue;
      final at = svc.nextDailyInstant(s.hour, s.minute);
      if (gate.reasonAt(prefs, at) != null) continue;
      await svc.scheduleOnce(
        id: s.id,
        category: NotifCategory.reminders,
        title: s.title,
        body: s.body,
        at: at,
        route: s.route,
      );
    }
  }
}
