// Headless LOCAL drain — runs the connect → drain → store-locally flow with NO UI,
// NO Provider, and (since the cloud excision) NO upload. It may add an automatic
// light derive when the saved calculation-power policy allows it.
// Invoked by the iOS CoreBluetooth-restoration RECOVERY path (ios_ble_restore.dart)
// when the band reappears after the live connection dropped.
//
// There is NO OS periodic scheduler on Android (the old WorkManager tasks were
// removed — background_derivation.dart is a tombstone; main.dart still cancels
// their persisted registrations by name). iOS registers opportunistic BGTasks
// (ios_bg_task.dart) that are never guaranteed. Continuous capture is the
// kept-alive live connection in AppState. This is purely the relaunch-recovery
// fallback that pulls the band's offline flash backlog into the local SQLite
// store (lib/data/db.dart), the system of record. A missed run is harmless;
// the next reconnect catches up from the non-destructive cursor.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/adapters/_registry.dart' show kWhoopGen4;
import '../ble/adapters/host.dart' show BandHost;
import '../ble/adapters/whoop_gen4.dart' show WhoopFramedAdapter;
import '../ble/ble_engine.dart';
import '../ble/ble_state.dart' show AlarmConfirmation;
import '../ble/colmi_link.dart';
import '../ble/session_link.dart';
import '../ble/coros_link.dart';
import '../ble/garmin_link.dart';
import '../ble/miband_link.dart';
import '../ble/oura_link.dart';
import '../ble/pebble_link.dart';
import '../ble/ultrahuman_link.dart';
import '../compute/derivation_engine.dart';
import '../compute/calc_power_policy.dart';
import '../compute/profile.dart';
import '../data/day_label.dart' show dayLabelOf;
import '../data/db.dart';
import 'import_gate.dart';
import '../ecg/ecg_guard_store.dart';
import '../ecg/ecg_recovery.dart';
import '../ecg/ecg_transport.dart';
import '../state/feature_flags.dart';
import '../state/power_source.dart';
import '../state/prefs.dart';
import '../wake/wake_settings.dart' show gateNaturalWake;
import '../wake/wake_confirmation.dart';
import '../wake/wake_stores.dart'
    show DbWakeConfirmationStore, loadWakeUpgradeState;
import '../notify/reminder_sleep_refresh.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../state/alarm_schedule.dart';
import 'band_ownership.dart';
import 'dev_log.dart';
import 'high_freq_wake_window.dart';
import 'reset_gate.dart';
import 'paired_device.dart';
import 'sync_policy.dart';

/// Headless mirror of the foreground `AlarmConfirmation` self-heal: an
/// ALARM_SET event (56) means the strap has this arm latched, independent of
/// whatever `armNextScheduledOccurrence` decided this cycle (its same-epoch
/// dedupe returns `epoch: null` and skips the re-arm/poll block entirely, so
/// this is the only place headless ever sees a live confirmation). Extracted
/// so the write can be unit-tested without the full drain harness.
///
/// An alarm FIRED event (57/58) is also wake evidence: it is noted from the
/// event's own stamp [tsEpoch] (never the time this sync delivered it; with no
/// stamp nothing is invented) into the persisted store the foreground reads
/// after a relaunch. Returns the confirmed wake moment when that note
/// completed the double confirmation, else null. Never throws.
@visibleForTesting
Future<int?> handleHeadlessAlarmEvent(int id, {int? tsEpoch}) async {
  if (id == proto.EventId.strapDrivenAlarmSet) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('alarm_epoch_confirmed', true);
    return null;
  }
  if (tsEpoch == null ||
      (id != AlarmConfirmation.kEvtStrapExecuted &&
          id != AlarmConfirmation.kEvtAppExecuted)) {
    return null;
  }
  try {
    return await WakeConfirmationRecorder(DbWakeConfirmationStore()).note(
        WakeEvidenceKind.alarmFired,
        DateTime.fromMillisecondsSinceEpoch(tsEpoch * 1000));
  } catch (e) {
    _bgLog('[bgsync] wake evidence (alarm fired) not recorded: $e');
    return null;
  }
}

/// Headless re-arm + latch wait. No live AppState here to catch a late
/// ALARM_SET (event 56) the way the foreground grace timer does, so wait for
/// it inline, the same grace window as AlarmConfirmation, before this
/// headless connection closes. The window opens BEFORE the write: setAlarm
/// can sit up to 5s on a reply the strap never echoes, and a 56 landing in
/// that wait is still this arm's latch. Not confirmed within the window still
/// persists the epoch (optimistic, matching the foreground write) but as
/// unconfirmed, so the 7pm safety check (AppState._alarmArmedTonight) won't
/// wrongly treat an un-latched headless arm as covering tonight. If the wake
/// is cut short mid-wait nothing is persisted, so the next connect re-arms
/// instead of deduping on a stale epoch. Returns the arm result and whether
/// the latch was seen, for the caller's log line.
@visibleForTesting
Future<({AlarmArmResult result, bool confirmed})> headlessArmAndConfirm(
    Future<AlarmArmResult> Function() arm,
    Future<bool> Function(int sinceMs) latchedSince) async {
  final armedAtMs = DateTime.now().millisecondsSinceEpoch;
  final result = await arm();
  final prefs = await SharedPreferences.getInstance();
  var confirmed = false;
  if (result.disabled) {
    await prefs.remove('alarm_epoch');
    await prefs.remove('alarm_epoch_confirmed');
  } else if (result.epoch != null) {
    confirmed = await awaitAlarmLatch(() => latchedSince(armedAtMs));
    await prefs.setInt('alarm_epoch', result.epoch!);
    await prefs.setInt('alarm_set_at_ms', armedAtMs);
    await prefs.setBool('alarm_epoch_confirmed', confirmed);
  }
  return (result: result, confirmed: confirmed);
}

/// One line of a headless run: the debug console AND the persistent dev log,
/// tagged `headless`. `[bgsync]` lines are always persisted ([DevLog]'s
/// always-on tags); pass [always] to override.
void _bgLog(String line, {bool? always}) {
  debugPrint(line);
  DevLog.write(line, source: 'headless', always: always);
}

bool _mentionsAlarm(String l) => l.toLowerCase().contains('alarm');

/// Load the local profile (no Provider in the headless isolate).
Future<Profile> loadHeadlessProfile() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('local_profile_json');
    if (raw == null) return const Profile();
    return Profile.fromMap((jsonDecode(raw) as Map).cast<String, dynamic>());
  } catch (_) {
    return const Profile();
  }
}

/// Every headless caller must use the same commit-before-ACK persistence path.
BleEngine createHeadlessSyncEngine({
  required PairedDevice paired,
  void Function(int records)? onCommitted,
  void Function(Object error)? onCommitError,
  void Function(int moment)? onWakeConfirmed,
}) {
  late final BandHost bandHost;
  final engine = BleEngine(
    // EVERY write below is gated on [ResetGate]: a reset can begin at any
    // point during a drain, and these callbacks are the reason it is not
    // enough for AppState to guard only its own. Refusing loses nothing —
    // none of it has been ACKed, so it is all still on the band.
    onRecord: (sample, raw) async {
      if (ResetGate.active) return;
      await LocalDb.insertRecord(raw, sample);
    },
    onState: (_) {},
    // This path drains exactly the one paired band (PairedDevice.load()),
    // so kPrimaryDeviceId is the correct value here, not a placeholder.
    // The engine stamps kPrimaryDeviceId and the band profile on the event
    // itself. Persist only: the headless drain must NOT dispatch gestures.
    // A wake confirmation this event completed is handed to
    // [onWakeConfirmed] so the run can re-derive that night after the drain.
    onEvent: (e) async {
      if (ResetGate.active) return;
      await LocalDb.insertStrapEvent(e);
      final moment =
          await handleHeadlessAlarmEvent(e.eventId, tsEpoch: e.tsEpoch);
      if (moment != null) onWakeConfirmed?.call(moment);
    },
    // The alarm lines (SET_ALARM_TIME, arm accepted/rejected, events) are the
    // evidence of whether tonight's alarm latched, so they are always
    // persisted; the rest of the drain chatter only in developer mode.
    log: (l) => _bgLog('[bgsync] $l', always: _mentionsAlarm(l)),
    onRecordsBatch: (raws, samples) async {
      if (ResetGate.active) return;
      await LocalDb.insertRecordsBatch(raws, samples);
    },
    // Routed through BandHost (M1a) rather than calling
    // LocalDb.commitSyncBatch directly — same durable commit, same
    // arguments, one extra await frame, and the SAME failure contract:
    // `commitNativeBatch` rethrows so `DrainController.commit` still reads
    // durability from a throw and `TrimAckPolicy` still blocks the ACK.
    onCommitBatch: (raws, samples, trimTokenHex,
        {archives, ecgRawPackets, deviceFamily}) async {
      try {
        // THROWS, never silently succeeds. This is the ACK gate: only
        // `onCommit` can bank raws + archives + trim cursor in one
        // transaction, and DrainController reads durability FROM A THROW
        // (see its safe-trim invariant). Returning quietly here would tell
        // the drain the chunk was banked, it would ACK, and the band would
        // trim flash that this reset refused to store — turning a race into
        // real data loss on a band the user may not be deleting after all if
        // the reset then fails. A throw blocks the ACK and the records stay
        // on the strap.
        if (ResetGate.active) {
          throw StateError('data reset in progress — refusing to commit');
        }
        await bandHost.commitNativeBatch(raws, samples, trimTokenHex,
            archives: archives,
            ecgRawPackets: ecgRawPackets,
            deviceFamily: deviceFamily);
      } catch (e) {
        onCommitError?.call(e);
        rethrow;
      }
      onCommitted?.call(samples.length);
    },
    onArchiveRecord: (raw) async {
      if (ResetGate.active) return;
      await LocalDb.archiveRawRecord(raw);
    },
    // A WHOOP MG left generating by a dead process must be cleaned up
    // BEFORE this drainer claims history — same rule as the foreground
    // engine, controller-free.
    onReadyEcgRecovery: (e) => ecgRecoverRetainedGuard(
      guard: PrefsEcgGuardStore(),
      serial: paired.serial,
      cleanup: () async {
        final out = await e.ecgRecoveryCleanup();
        return EcgCommandListResult([
          for (final o in out)
            EcgMemberOutcome(o.label,
                written: o.written, succeeded: o.succeeded),
        ]);
      },
      log: (l) => _bgLog('[bgsync] $l', always: _mentionsAlarm(l)),
    ),
    cursorReader: (base) =>
        LocalDb.getCursorInt(LocalDb.cursorKeyFor(base, LocalDb.kPrimaryDeviceId)),
    // Mark this as the background drainer: if the foreground app engine already
    // owns the band (same process — iOS restore-wake OR Android headless boot /
    // foreground service), this engine YIELDS instead of opening a second drain
    // that would double-ACK the same offload and stall the trim cursor.
    isBackgroundDrainer: true,
  );
  bandHost = BandHost(
    adapter: WhoopFramedAdapter(engine, kWhoopGen4),
    deviceId: LocalDb.kPrimaryDeviceId,
    onLog: (msg) => _bgLog('[bgsync][COMMIT] $msg', always: false),
  );
  return engine;
}

/// Post-connect work every headless connect owes the band, whichever entry
/// point made it: pin the discovered generation, then program the HighFreq
/// wake window ([headlessWakeWindowPlan]) for the imminent alarm.
Future<void> prepareHeadlessLink(BleEngine engine, PairedDevice paired) async {
  // Pin the discovered generation onto the pairing record, exactly like the
  // foreground engine-state heal does — a headless-only phone would
  // otherwise re-probe the connect route on every wake forever.
  final gen = engine.state.generation;
  if ((gen == 'gen4' || gen == 'gen5') && gen != paired.generation) {
    await PairedDevice.save(paired.remoteId, paired.serial, generation: gen);
  }
  // Read BEFORE the (possibly long) sync; the re-arm re-reads the schedule
  // fresh on its own (see PR #403).
  final plan = await headlessWakeWindowPlan();
  await engine.applyHighFreqWakeWindow(
    enabled: plan.shouldEnable,
    targetWake: plan.targetWake,
    duration: plan.lease,
    intervalSeconds: 61, // gen5 rejects <= 60

    reason: plan.source,
  );
  // The dev log is the only evidence afterwards.
  _bgLog('[bgsync] HighFreq wake window: source=${plan.source} '
      'samples=${plan.sampleCount} enabled=${plan.shouldEnable} '
      'target=${plan.targetWake?.toIso8601String()}');
}

/// Test seams for the headless entries: the phone's power the gate reads, and
/// how the entries build their [DerivationEngine]. Null = production.
@visibleForTesting
PowerSource? debugHeadlessPowerSource;
@visibleForTesting
DerivationEngine Function({void Function(String)? log, bool background})?
    debugHeadlessEngineFactory;

/// The saved Calculations mode (balanced when unset or unknown). Read from
/// SharedPreferences directly: the headless isolate has not loaded [Prefs].
Future<CalcPowerMode> _savedCalcPowerMode() async {
  final rawMode =
      (await SharedPreferences.getInstance()).getString(Prefs.calcPowerMode);
  return CalcPowerMode.values
      .firstWhere((m) => m.name == rawMode, orElse: () => CalcPowerMode.balanced);
}

/// The one place a headless entry builds its [DerivationEngine]. It carries the
/// finalization audit like the foreground engine: the saved Calculations mode
/// and the phone's power read at the moment of finalization. Power that cannot
/// be read counts as unplugged, so the day is marked pending, never audited.
Future<DerivationEngine> newHeadlessDerivationEngine(
    void Function(String) log) async {
  final engine = (debugHeadlessEngineFactory ?? DerivationEngine.new)(
      log: log, background: true);
  // No coordinator publishes for a headless pass: the engine restamps Today's
  // freshness itself once its writes land (see DerivationEngine.onSettled).
  engine.onSettled = LocalDb.refreshComputeFreshness;
  try {
    engine.auditPolicy = CalcPowerPolicy(await _savedCalcPowerMode());
    engine.auditPowerRead = () async {
      final owned = debugHeadlessPowerSource == null;
      final source = debugHeadlessPowerSource ?? BatteryPowerSource();
      try {
        return await source.read();
      } catch (_) {
        return PowerState.unplugged;
      } finally {
        if (owned) (source as BatteryPowerSource).dispose();
      }
    };
  } catch (_) {
    // Mode unreadable: no audit and no pending mark, as before.
  }
  return engine;
}

/// Whether an automatic derive may run in this headless wake or iOS background
/// task: the saved Calculations mode against the phone's power now. A platform that
/// cannot report power leaves the pass allowed, so failed power detection
/// never blocks a durable raw-data drain or strands pending computation.
Future<bool> mayRunHeadlessAutomaticDerive({PowerSource? powerSource}) async {
  BatteryPowerSource? ownedSource;
  try {
    final prefs = await SharedPreferences.getInstance();
    final rawMode = prefs.getString(Prefs.calcPowerMode);
    var mode = CalcPowerMode.balanced;
    for (final candidate in CalcPowerMode.values) {
      if (candidate.name == rawMode) {
        mode = candidate;
        break;
      }
    }
    final source = powerSource ??
        debugHeadlessPowerSource ??
        (ownedSource = BatteryPowerSource());
    return CalcPowerPolicy(mode).mayDeriveAutomatically(await source.read());
  } catch (_) {
    return true;
  } finally {
    ownedSource?.dispose();
  }
}

/// The post-drain light derive of [runHeadlessSync], behind the power gate.
@visibleForTesting
Future<void> headlessDeriveAfterSync() async {
  if (await mayRunHeadlessAutomaticDerive()) {
    try {
      await (await newHeadlessDerivationEngine(
        (l) => _bgLog('[bgsync-derive] $l'),
      )).run(await loadHeadlessProfile());
    } catch (e) {
      _bgLog('[bgsync] derive skipped: $e');
    }
  } else {
    _bgLog('[bgsync] automatic derive held by Maximum battery mode.');
  }
  try { await refreshHeadlessReminderSleep(); } catch (e) {
    _bgLog('[bgsync] reminder refresh deferred: $e');
  }
}

/// The headless half of "a confirmation finalizes the night". When a note made
/// during this run completed the wake confirmation ([moment], what
/// [handleHeadlessAlarmEvent] returned), the wake day is re-derived NOW, forced,
/// the way the foreground does: otherwise the night stays scored from the data
/// as it was until some unrelated later pass. Goes through the headless engine
/// builder and behind the same power gate as every automatic headless derive.
/// Called only inside [runHeadlessSync], so it already holds the headless
/// gate's slot (`HeadlessSyncGate`: skip, never queue). Never throws; true when
/// the derive ran.
@visibleForTesting
Future<bool> headlessDeriveConfirmedWakeDay(int moment) async {
  if (!await mayRunHeadlessAutomaticDerive()) {
    _bgLog('[bgsync] wake-day derive held by Maximum battery mode.');
    return false;
  }
  try {
    final day = await DbWakeConfirmationStore().blockDayId() ??
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(moment * 1000));
    await (await newHeadlessDerivationEngine(
      (l) => _bgLog('[bgsync-derive] $l'),
    )).runDays(await loadHeadlessProfile(), {day}, force: true);
    await refreshHeadlessReminderSleep();
    return true;
  } catch (e) {
    _bgLog('[bgsync] wake-day derive skipped: $e');
    return false;
  }
}

/// The band's high-frequency plan for a headless run. Same inputs as the
/// foreground refresh, so the two cannot disagree about whether this is a
/// collection window: the saved expected sleep schedule (it adds a window, it
/// never removes one), the history habit, and the Natural window of the armed
/// alarm — or, when no epoch is tracked, of the schedule's next occurrence
/// ([plannedCollectionWindow]). Read BEFORE the (possibly long) sync; the
/// re-arm block re-reads the schedule fresh on its own (see PR #403).
@visibleForTesting
Future<HighFreqWakePlan> headlessWakeWindowPlan({DateTime? now}) async {
  final schedule = fillDefaultAlarmSchedule([
    for (final r in await LocalDb.alarmScheduleRows())
      AlarmScheduleEntry.fromRow(r),
  ]);
  final prefs = await SharedPreferences.getInstance();
  await FeatureFlags.ensureLoaded(); // a headless run has no launch hook
  final armed = plannedCollectionWindow(
    epoch: prefs.getInt('alarm_epoch'),
    schedule: schedule,
    upgrade: gateNaturalWake(await loadWakeUpgradeState()),
    now: now,
    ackedThroughEpochSec: prefs.getInt('wake_acked_epoch'),
  );
  return HighFreqWakeWindow.planNow(
    now: now,
    scheduledWindowEnd: armed?.windowEnd,
    scheduledWindowMinutes: armed?.minutes ?? 0,
    expectedSchedule: loadSavedExpectedSleepSchedule(prefs),
  );
}

/// Arms the next weekly-schedule occurrence on a headless connection. The band
/// holds one armed epoch, so every connect path has to re-arm or the day after
/// a fired alarm stays unarmed. Feature 1's arming engine, headless half: "on
/// every successful connect AND after each headless sync". [phase] only labels
/// the dev-log line. Never throws.
Future<void> rearmHeadlessAlarm(BleEngine engine,
        {String phase = 'on connect'}) =>
    _headlessArm(engine, phase);

/// One headless arm pass: no AppState here, so the schedule read and the
/// `alarm_epoch` persistence go straight through LocalDb/SharedPreferences —
/// the same store the foreground path uses, so whichever side runs next sees a
/// consistent value. The schedule is read fresh each time (not reused from the
/// window check) in case the user changed it while the link was busy. Never
/// throws; the outcome goes to the debug log AND the persistent dev log.
Future<void> _headlessArm(BleEngine engine, String phase) async {
  void note(String line) => _bgLog('[bgsync] $line');

  try {
    final schedule = fillDefaultAlarmSchedule([
      for (final r in await LocalDb.alarmScheduleRows())
        AlarmScheduleEntry.fromRow(r),
    ]);
    final prefs = await SharedPreferences.getInstance();
    final out = await headlessArmAndConfirm(
      () => armNextScheduledOccurrence(
        engine: engine,
        schedule: schedule,
        currentArmedEpoch: prefs.getInt('alarm_epoch'),
        // An occurrence the user acknowledged and cancelled must not be
        // re-armed by a background sync.
        ackedThroughEpochSec: prefs.getInt('wake_acked_epoch'),
      ),
      LocalDb.alarmSetConfirmedSince,
    );
    final result = out.result;
    if (result.disabled) {
      note('[alarm] headless arm ($phase): schedule empty, band alarm disabled.');
    } else if (result.epoch != null) {
      note('[alarm] headless arm ($phase): wrote epoch=${result.epoch} '
          'confirmed=${out.confirmed}.');
    } else if (result.refused) {
      note('[alarm] headless arm ($phase): the band did not take the alarm.');
    }
  } catch (e) {
    note('[alarm] headless arm ($phase) skipped: $e');
  }
}

/// One headless LOCAL drain pass. Safe to call from a background isolate. Never
/// throws. Connects-by-id if reachable, drains whatever the band buffered to
/// flash into local storage (non-destructive cursor — catches up everything since
/// last time), and disconnects. No network.
Future<bool> runHeadlessSync({BandLease? lease}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final ownedLease = lease ?? BandOwnership.tryAcquireHeadless();
  if (ownedLease == null) {
    _bgLog(
      '[bgsync] skipped — foreground or another headless session owns the band '
      '(${BandOwnership.debugState}).',
    );
    return true;
  }
  _bgLog(
    '[bgsync] acquired headless lease=${ownedLease.token} '
    '(${BandOwnership.debugState})',
  );
  try {
    // "Delete everything" is running in this same process — see [ResetGate].
    // Checked BEFORE PairedDevice.load(), which is the only thing standing
    // between a reset and a fresh drain today, and only by accident: the reset
    // calls `prefs.clear()`, so a LATER run reads no paired device and bails
    // here. That is incidental protection for future runs and none at all for
    // a drain already in flight.
    if (ResetGate.active) {
      _bgLog('[bgsync] a data reset is running — not starting a drain.');
      return true;
    }
    // An import is running, or one was killed and waits for its resume: the
    // drain would ACK into tables the import is still merging. Skipped, not
    // queued; the band keeps its flash (see [ImportGate]).
    await ImportGate.probe();
    if (ImportGate.check('headless.sync') case final SyncRefused r) {
      _bgLog('[bgsync] ${r.message} — not starting a drain.');
      return true;
    }
    final paired = await PairedDevice.load();
    if (paired == null) {
      _bgLog('[bgsync] not paired — nothing to do.');
      return true;
    }

    // The wake moment a note made during THIS run confirmed, if one did: the
    // night it finalizes is re-derived after the drain.
    int? confirmedWake;
    // Connect → drain → store. No live streams (battery): in and out.
    final engine = createHeadlessSyncEngine(
      paired: paired,
      onWakeConfirmed: (moment) => confirmedWake = moment,
    );

    // connect() subscribes → SET_CLOCK → INIT, so the historical offload is already
    // streaming when this returns. We then await it reaching HISTORY_COMPLETE.
    final connected = await connectHeadless(
      engine,
      () => engine.connectToRemoteId(paired.remoteId,
          generationHint: paired.generation),
    );
    if (!connected) {
      _bgLog(
        '[bgsync] strap not reachable this cycle — will catch up next time.',
      );
      await checkSyncStaleness();
      return true;
    }
    try {
      await prepareHeadlessLink(engine, paired);
      // THE ALARM BEFORE THE DRAIN. The foreground path arms on connect, ahead
      // of its burst; this one used to arm only after `runSync()`, so a drain
      // that threw, or an OS that ended the background slot mid-drain (both
      // routine on a large backlog), left tonight's alarm unarmed. Arm now, and
      // again after the drain (the second pass is deduped to nothing unless the
      // schedule changed meanwhile). This write overlaps the INIT drain the way
      // the foreground's and the Shortcut's connect-time writes do.
      await _headlessArm(engine, 'before the drain');
      // Await the full backlog (default timeout): a phone-free run/sleep can leave a
      // large offline backlog on the band's flash. The wait itself never aborts —
      // if iOS cuts the background window short, the offload persists what it got
      // (flush-before-ACK) and the next wake resumes from the (now-advanced)
      // cursor. Only once the wait is over does [finishHeadlessDrain] end a task
      // still running, before the alarm writes. No live streams (battery):
      // connect → listen → store → ACK → derive → disconnect.
      try {
        await engine.runSync();
      } finally {
        // Re-arm after the drain, also when the drain threw.
        await finishHeadlessDrain(engine,
            rearm: (_) => _headlessArm(engine, 'after the drain'));
      }
    } finally {
      await disconnectHeadless(engine);
    }
    // A confirmation this run completed finalizes the night: re-derive that day
    // first (forced, as the foreground does), ahead of the light pass.
    final confirmed = confirmedWake;
    if (confirmed != null) await headlessDeriveConfirmedWakeDay(confirmed);
    // Within the SAME background wake slot: capture raw AND derive the fresh
    // window (bounded LIGHT pass — newest affected day only — so we stay inside
    // the short iOS execution budget). Best-effort; if the slot ends first, the
    // light pass on the next drain or the foreground finalize catches up.
    await headlessDeriveAfterSync();
    _bgLog('[bgsync] done (local drain + light derive).');
    await checkSyncStaleness();
    return true;
  } catch (e) {
    _bgLog('[bgsync] error (ignored): $e');
    return true;
  } finally {
    _bgLog(
      '[bgsync] releasing headless lease=${ownedLease.token} '
      '(${BandOwnership.debugState})',
    );
    BandOwnership.release(ownedLease);
    // Piggyback paired sensors on the same OS wake window, after the band
    // work is fully done so neither can ever delay or interfere with WHOOP's
    // own timing. Both `sync()` calls already no-op when nothing is paired
    // and never throw, but this is the one shared headless entry point (every
    // wake source funnels through runHeadlessSync via HeadlessSyncGate) so a
    // failure in either must not be allowed to escape and mark the WHOOP
    // cycle as errored.
    try {
      await OuraLink.instance.sync();
    } catch (e) {
      _bgLog('[bgsync] oura sync skipped: $e');
    }
    // Same piggyback, same reasoning: CorosLink.sync() no-ops when nothing is
    // paired and never throws, but this is the one shared headless entry
    // point, so a failure here must not escape either.
    try {
      await CorosLink.instance.sync();
    } catch (e) {
      _bgLog('[bgsync] coros sync skipped: $e');
    }
    // Same piggyback, same reasoning: GarminLink.sync() no-ops when nothing
    // is paired and never throws, but this is the one shared headless entry
    // point, so a failure here must not escape either.
    try {
      await GarminLink.instance.sync();
    } catch (e) {
      _bgLog('[bgsync] garmin sync skipped: $e');
    }
    // Same piggyback, same reasoning: UltrahumanLink.sync() no-ops when
    // nothing is paired and never throws, but this call must not be allowed
    // to escape and mark the WHOOP cycle as errored either way.
    try {
      await UltrahumanLink.instance.sync();
    } catch (e) {
      _bgLog('[bgsync] ultrahuman sync skipped: $e');
    }
    // Same reasoning, same slot, for a paired Mi Band: MiBand234Link.sync()
    // also no-ops when nothing is paired and never throws, but guard it
    // anyway so a surprise failure here still can't mark the WHOOP cycle
    // errored.
    try {
      await MiBand234Link.instance.sync();
    } catch (e) {
      _bgLog('[bgsync] miband234 sync skipped: $e');
    }
    // Same piggyback, same reasoning: a bounded connect-drain window that
    // no-ops when nothing is paired and must never mark the WHOOP cycle
    // errored on its own failure.
    try {
      await PebbleLink.instance.sync();
    } catch (e) {
      _bgLog('[bgsync] pebble sync skipped: $e');
    }
    // Same piggyback, same reasoning: no-ops when unpaired, must never let a
    // failure here mark the WHOOP cycle as errored.
    try {
      await ColmiLink.instance.sync();
    } catch (e) {
      _bgLog('[bgsync] colmi sync skipped: $e');
    }
    // Thermometer and scales: same piggyback; each no-ops when unpaired and
    // only reaches a device that happens to be awake and nearby.
    for (final link in SessionLink.all) {
      try {
        await link.sync();
      } catch (e) {
        _bgLog('[bgsync] ${link.entry.id} sync skipped: $e');
      }
    }
  }
}

// ── staleness escalation (meta-layer over the whole reconnect/sync ladder) ──
// See sync_policy.dart's stalenessTierFor doc. Evaluated at the end of every
// headless cycle (success OR a failed connect attempt — both are meaningful
// signals here), independent of THIS cycle's outcome: it reads the durable
// `rec_ts_hw` cursor, which reflects the full sync history, not just this run.
const String _kLastStalenessNotifiedMs = 'last_staleness_notified_ms';

/// The tail of a headless drain: settle the link's history, THEN write the
/// alarm (gen5: SET_CLOCK + SET_ALARM). runSync() only stopped WAITING; the
/// band may still be transmitting, and a retry armed by an earlier terminal,
/// an auto-continue or a periodic/prompt trigger could put opcode 22 between
/// those writes. So the running task is ended (one abort; the band keeps its
/// checkpoint, nothing un-ACKed is lost) and history is held on this link
/// until it closes — unconditionally, since no offload in flight does not
/// mean no retry pending. The `finally` in [runHeadlessSync] disconnects,
/// which ends the hold. [rearm] is a seam for tests.
///
/// Only this path settles. A Shortcut sync re-arms right after connect and
/// then keeps draining on the same link, so holding history there would stop
/// its own drain; its connect-time writes overlap the INIT drain like the
/// foreground app's do.
@visibleForTesting
Future<void> finishHeadlessDrain(
  BleEngine engine, {
  Future<void> Function(BleEngine) rearm = rearmHeadlessAlarm,
}) async {
  if (engine.offloadActive) {
    _bgLog('[bgsync] drain still active after the wait — ending the '
        'history task before configuration writes.');
  }
  await engine.endHistoryForLink(reason: 'headless_config_writes');
  await rearm(engine);
}

/// Connect a headless engine. A connect that FAILS can still have taken in
/// another client's records before the step that failed (setup subscribes
/// to notifications first), and the failed link's final bank of them runs
/// detached — so before the run gives up, wait for it exactly as
/// [disconnectHeadless] does. [connect] is the connect attempt itself.
Future<bool> connectHeadless(
  BleEngine engine,
  Future<bool> Function() connect, {
  Duration bound = const Duration(seconds: 12),
}) async {
  var connected = false;
  try {
    connected = await connect();
    return connected;
  } finally {
    if (!connected) await engine.settleShutdownBanks(bound: bound);
  }
}

/// Close a headless link and wait — bounded — for the rows another client's
/// transfer left on it to be stored: disconnect does not wait for that final
/// bank (a reconnect must not), but a headless run is done when it returns
/// and its process may be suspended right after, before rows that are not
/// durable yet could be. Used by every headless entry point (the
/// background sync and the Shortcut sync).
Future<void> disconnectHeadless(
  BleEngine engine, {
  Duration bound = const Duration(seconds: 12),
}) async {
  try {
    await engine.disconnect();
  } finally {
    await engine.settleShutdownBanks(bound: bound);
  }
}

/// [allowPermissionPrompt] defaults to `false` because this function's
/// PRIMARY callers (below, inside [runHeadlessSync]) run headless — see
/// NotificationCenter.emit's doc on why a background context must never
/// trigger the OS's interactive authorization prompt. app_state.dart's
/// foreground call (via runCadenceChecks, a genuinely contextual moment)
/// passes `true` explicitly.
Future<void> checkSyncStaleness({bool allowPermissionPrompt = false}) async {
  try {
    final recTsHw = await LocalDb.getCursorInt('rec_ts_hw');
    // Never synced at all (e.g. freshly paired, first drain still pending) —
    // nothing to escalate; that's a distinct, already-visible onboarding
    // state, not silent staleness.
    if (recTsHw == null || recTsHw <= 0) return;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tier = stalenessTierFor(nowSec - recTsHw);
    if (tier != StalenessTier.notify) return;

    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_kLastStalenessNotifiedMs);
    final lastAt =
        lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
    final now = DateTime.now();
    if (!shouldRenotifyStaleness(lastAt, now)) return;

    final hoursStale = (nowSec - recTsHw) ~/ 3600;
    final shown = await NotificationCenter.instance.emit(
      NotificationEvent(
        // Date-bucketed so a legitimate re-fire after the cooldown isn't
        // blocked by putNotification's INSERT-OR-IGNORE dedupe.
        dedupeKey: '${dayLabelOf(now)}:sync_stale',
        category: NotifCategory.device,
        // Quiet hours DROP a normal-priority event; nothing queues it for the
        // morning. The 48-hour cooldown below is therefore only spent when the
        // event was actually presented.
        priority: NotifPriority.normal,
        title: "Your band has not synced",
        body: 'No new data for about $hoursStale hours. Open OpenStrap to '
            'reconnect the band.',
        date: dayLabelOf(now),
        // Home: its day card carries the synced-through line and the sync
        // button this body points at. Profile shows neither.
        route: '/today',
      ),
      allowPermissionPrompt: allowPermissionPrompt,
    );
    if (!shown) {
      // The gate refused it (quiet hours on an overnight wake is the common
      // case). Burning the cooldown here silenced the backstop for another 48
      // hours over a notification nobody ever saw.
      _bgLog('[bgsync] staleness notification dropped by the gate.');
      return;
    }
    await prefs.setInt(_kLastStalenessNotifiedMs, now.millisecondsSinceEpoch);
    _bgLog(
      '[bgsync] staleness notification fired (hours_stale=$hoursStale).',
    );
  } catch (e) {
    _bgLog('[bgsync] staleness check skipped: $e');
  }
}
