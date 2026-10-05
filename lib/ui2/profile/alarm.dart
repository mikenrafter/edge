// The band alarm.
//
// This screen exists because the alarm is the one thing in the app that keeps
// working when the app does not. It is armed on the STRAP's own real-time
// clock, so it survives the app being killed, the phone rebooting, and the
// phone being out of range entirely. The rebuild shipped with no alarm UI at
// all while `AppState` still restored `alarm_epoch` on launch and still ran the
// confirmation state machine — which means an alarm armed on an older build
// went on firing every morning with nothing anywhere to see it or stop it.
//
// The honesty problem is confirmation. Writing SET_ALARM to the band is not
// evidence that the band latched it; the strap says so separately, by emitting
// event 56, and it might never arrive. And after a relaunch there is no live
// confirmation at all — only the epoch we wrote down. Three different states,
// and the screen says which one it is rather than drawing a confident green
// tick over all three.
//
// A single next-occurrence time picker used to live here. It is gone: the
// weekly schedule below is now the ONLY thing that arms the band (AppState
// computes the next enabled occurrence on every connect/sync), so a second,
// independent "set one alarm" affordance would just be a second source of
// truth that the schedule engine silently overwrites on the next sync.
//
// EDITING IS A DRAFT. Every row edits an in-memory [AlarmDraft] of the
// whole week, Natural and Gradual settings included. Nothing is saved or sent
// until Save at the top: one DB transaction, then ONE write of the fixed alarm
// at T to the band (skipped when the band already holds it). Natural Wake and
// Gradual Wake are never written to the band at all; the phone sends a live
// haptic when it decides to. Leaving with unsaved edits, or while a save is
// still reaching the band, asks first. This file must not call
// AppState.setScheduleDay (it saves and arms at once); a test guards that.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state/alarm_draft.dart';
import '../../state/alarm_schedule.dart';
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../wake/wake_settings.dart';
import '../../wake/wake_trace_text.dart';
import '../screens/home_screen.dart' show weekdayShortName;
import '../ui2.dart';
import 'profile.dart' show SetRow, SettingsAccordion, kDisabledOpacity;
import 'settings.dart' show editExpectedSleepSchedule;

/// What we actually know about the armed alarm.
enum AlarmArmState {
  /// Nothing armed.
  none,

  /// Written to the band; its confirmation event may still be in flight.
  pending,

  /// The band emitted ALARM_SET — it latched.
  confirmed,

  /// Armed, but unconfirmed: either the band never acknowledged the write, or
  /// this is an alarm from a previous run of the app and there is no live
  /// confirmation to read. Both mean the same thing to the user — we cannot
  /// promise it will fire — so they share one state rather than being dressed
  /// up as two.
  unknown,
}

/// The route the app pushes. It owns nothing but the wiring: AppState in,
/// [AlarmScreenView] out. All editing happens in the view's draft.
class AlarmScreen extends StatefulWidget {
  const AlarmScreen({super.key});

  @override
  State<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends State<AlarmScreen> {
  Future<List<String>>? _trace;
  int? _traceEpoch;
  int _traceRevision = -1;

  /// The plain-words decision trace for the armed wake. Reloaded when the armed
  /// occurrence changes AND each time a tick appends to it (the revision on
  /// [WakeController.traceRevision]). A reload is one bounded query; the
  /// FutureBuilder drops a result whose screen is gone or superseded, so no
  /// state is touched after an await.
  static Future<List<String>> _loadTrace(AppState app, int epoch) async {
    try {
      final entries = await app.wake.traceFor(
        DateTime.fromMillisecondsSinceEpoch(epoch * 1000),
      );
      return describeWakeTrace(entries);
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final caps = c.caps;
    final epoch = app.alarmEpoch;
    final sleep = app.sleepOperations.schedule;
    return ValueListenableBuilder<int>(
      valueListenable: app.wake.traceRevision,
      builder: (c, revision, _) {
        if (epoch != _traceEpoch || revision != _traceRevision) {
          _traceEpoch = epoch;
          _traceRevision = revision;
          _trace = epoch == null ? null : _loadTrace(app, epoch);
        }
        return FutureBuilder<List<String>>(
          future: _trace,
          builder: (c, trace) => AlarmScreenView(
            armedAt: epoch == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(epoch * 1000),
            state: epoch == null
                ? AlarmArmState.none
                : app.alarmConfirmed
                ? AlarmArmState.confirmed
                : app.alarmPending
                ? AlarmArmState.pending
                : AlarmArmState.unknown,
            connected: caps.has(Feature.alarmBandControls),
            schedule: app.alarmSchedule,
            onSave: app.saveAlarmDraft,
            onTest: app.testAlarmBuzz,
            onCancelAlarm: app.disableAlarm,
            upgradePending:
                app.wake.naturalEnabled && app.wake.upgradeExplanationPending,
            naturalWakeSupported: caps.has(Feature.naturalWake),
            onAcknowledgeUpgrade: (enable) =>
                app.wake.acknowledgeUpgrade(enableNatural: enable),
            hasExpectedSleep: sleep != null,
            expectedSleepLabel: sleep == null
                ? null
                : '${_clock(sleep.onsetMinute)} to ${_clock(sleep.wakeMinute)}',
            onSetSleepSchedule: () => editExpectedSleepSchedule(c, app),
            timelineFor: (at, entry) => app.wake.timelineAt(at, entry: entry),
            wakeTrace: trace.data ?? const [],
            resent: app.alarmResentUnconfirmed,
          ),
        );
      },
    );
  }

  static String _clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';
}

class AlarmScreenView extends StatefulWidget {
  final DateTime? armedAt;
  final AlarmArmState state;
  final bool connected;

  /// Injectable clock. "Tomorrow" vs "Later today" is relative, so a golden of
  /// this screen is otherwise a function of when the suite happens to run.
  final DateTime? now;

  /// The SAVED schedule: always exactly 7 entries in weekday order — see
  /// `fillDefaultAlarmSchedule` in state/alarm_schedule.dart, which is what
  /// [AppState.alarmSchedule] guarantees. The view edits a draft of it.
  final List<AlarmScheduleEntry> schedule;

  /// Save: persist the whole draft, arm the band once. Null = nothing to save
  /// to (previews), and Save stays inert.
  final Future<AlarmSaveOutcome> Function(List<AlarmScheduleEntry> entries)?
  onSave;

  /// Test buzz and "cancel the alarm" talk to the live band and throw when it
  /// is not connected — the screen reports the failure rather than pretending.
  final Future<void> Function()? onTest, onCancelAlarm;

  /// The Smart Wake -> Natural Wake explanation is waiting. While true the
  /// explanation card shows and Natural Wake stays off-limits.
  final bool upgradePending;
  final Future<void> Function(bool enableNatural)? onAcknowledgeUpgrade;

  /// FeatureFlag.naturalWake. False hides the Natural Wake row and the upgrade
  /// card, and the summary and timeline stop mentioning Natural.
  final bool naturalWakeSupported;

  /// Natural Wake needs the expected sleep schedule to tell a main sleep from a
  /// nap. Without one its row is dimmed, with the reason.
  final bool hasExpectedSleep;
  final String? expectedSleepLabel;
  final Future<void> Function()? onSetSleepSchedule;

  /// Draws a day's timeline (WakeController.timelineAt). Null computes the same
  /// thing from the draft directly.
  final WakeTimeline Function(DateTime wakeAt, AlarmScheduleEntry day)?
  timelineFor;

  /// The armed wake's decision trace, already in plain words.
  final List<String> wakeTrace;

  /// The app sent the armed alarm a second time because the band had not
  /// confirmed the first send, and it is still unconfirmed. The header says so.
  final bool resent;

  const AlarmScreenView({
    super.key,
    this.armedAt,
    this.state = AlarmArmState.none,
    this.connected = false,
    this.now,
    this.schedule = const [],
    this.onSave,
    this.onTest,
    this.onCancelAlarm,
    this.upgradePending = false,
    this.naturalWakeSupported = true,
    this.onAcknowledgeUpgrade,
    this.hasExpectedSleep = true,
    this.expectedSleepLabel,
    this.onSetSleepSchedule,
    this.timelineFor,
    this.wakeTrace = const [],
    this.resent = false,
  });

  @override
  State<AlarmScreenView> createState() => _AlarmScreenViewState();

  static String _hhmm(DateTime d) => _hhmmOf(d.hour, d.minute);

  static String _hhmmOf(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// "Tue 07:30" — the weekday plus the time, both from the ARMED instant
  /// (not merely from the schedule row), so this never claims a day the band
  /// hasn't actually latched yet.
  static String _dayAndTime(BuildContext c, DateTime at) =>
      '${weekdayShortName(at.weekday, AppLocalizations.of(c))} ${_hhmm(at)}';

  /// Short weekday label for a schedule row. [weekday] is the 0=Mon..6=Sun
  /// convention `AlarmScheduleEntry` uses; `weekdayShortName` wants
  /// `DateTime.weekday` (1=Mon..7=Sun), hence the `+ 1`.
  static String _weekdayLabel(BuildContext c, int weekday) =>
      weekdayShortName(weekday + 1, AppLocalizations.of(c));

  static String _whichDay(BuildContext c, DateTime d, DateTime now) {
    final l = AppLocalizations.of(c);
    final days = DateTime(
      d.year,
      d.month,
      d.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (days < 0) {
      return l?.alarmInThePast ?? 'Already passed';
    }
    if (days == 0) return l?.alarmLaterToday ?? 'Later today';
    if (days == 1) return l?.alarmTomorrow ?? 'Tomorrow';
    return l?.alarmInDays(days) ?? 'In $days days';
  }

  // Kept context-free and @visibleForTesting: the arm-state contract this
  // guards ("only `confirmed` may claim it") is tested without a widget tree.
  @visibleForTesting
  static String stateLabel(AlarmArmState s) => switch (s) {
    AlarmArmState.confirmed => 'Confirmed',
    AlarmArmState.pending => 'Waiting',
    AlarmArmState.unknown => 'Not confirmed',
    AlarmArmState.none => 'Not set',
  };

  static String _localizedStateLabel(BuildContext c, AlarmArmState s) {
    final l = AppLocalizations.of(c);
    return switch (s) {
      AlarmArmState.confirmed => l?.alarmStateConfirmed ?? 'Confirmed',
      AlarmArmState.pending => l?.alarmStateWaiting ?? 'Waiting',
      AlarmArmState.unknown => l?.alarmStateNotConfirmed ?? 'Not confirmed',
      AlarmArmState.none => l?.alarmStateNotSet ?? 'Not set',
    };
  }

  static Color _stateColor(AlarmArmState s) => switch (s) {
    AlarmArmState.confirmed => C.green,
    AlarmArmState.pending => C.blue,
    AlarmArmState.unknown => C.orange,
    AlarmArmState.none => C.blue,
  };

  static IconData _stateIcon(AlarmArmState s) => switch (s) {
    AlarmArmState.confirmed => LucideIcons.badgeCheck,
    AlarmArmState.pending => LucideIcons.loader,
    AlarmArmState.unknown => LucideIcons.circleHelp,
    AlarmArmState.none => LucideIcons.alarmClock,
  };

  static String _stateHeadline(BuildContext c, AlarmArmState s) {
    final l = AppLocalizations.of(c);
    return switch (s) {
      AlarmArmState.confirmed =>
        l?.alarmHeadlineConfirmed ?? 'The band has this alarm',
      AlarmArmState.pending =>
        l?.alarmHeadlinePending ?? 'Sent, waiting for the band to confirm',
      AlarmArmState.unknown =>
        l?.alarmHeadlineUnknown ?? 'We cannot tell whether this will fire',
      AlarmArmState.none => l?.alarmHeadlineNone ?? 'No alarm is set',
    };
  }

  static String? _stateDetail(BuildContext c, AlarmArmState s) {
    final l = AppLocalizations.of(c);
    return switch (s) {
      AlarmArmState.confirmed =>
        l?.alarmDetailConfirmed ?? 'The band confirmed it stored the alarm.',
      AlarmArmState.pending =>
        l?.alarmDetailPending ??
            'The write reached the band. Its confirmation usually arrives within '
                'a few seconds.',
      AlarmArmState.unknown =>
        l?.alarmDetailUnknown ??
            'The time above is the last one this app sent. The band '
                'has not confirmed it, or you set it in an earlier '
                'session, and the app cannot read the alarm stored on '
                'the band. Set it again while connected to be sure.',
      AlarmArmState.none => null,
    };
  }
}

enum _Leave { keep, discard, save }

class _AlarmScreenViewState extends State<AlarmScreenView> {
  late final AlarmDraft _draft = AlarmDraft(widget.schedule);

  /// Which weekday the day tabs have selected (0=Mon..6=Sun); both accordions
  /// show it. Seeded once, from the first day that is on, so switching a day
  /// on or off never moves it.
  late int _wakeDay = _draft.entries
      .firstWhere((e) => e.enabled, orElse: () => _draft.entry(0))
      .weekday;

  @override
  void didUpdateWidget(AlarmScreenView old) {
    super.didUpdateWidget(old);
    if (!identical(old.schedule, widget.schedule)) {
      _draft.rebase(widget.schedule);
    }
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  // ── leaving ────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final send = widget.onSave;
    if (send == null) return;
    await _draft.save(send);
  }

  /// Back button, system back and the nav-bar back all land here (PopScope).
  Future<void> _confirmLeave() async {
    if (_draft.sending) {
      final wait = await _ask<bool>(
        'Still sending to the band',
        'The band has not answered yet. If you leave, the band updates the '
            'next time it connects.',
        const [('Leave', false), ('Wait', true)],
      );
      if (!mounted || wait == null) return;
      if (!wait) {
        // The save keeps going in AppState; the band updates when it can.
        Navigator.of(context).pop();
        return;
      }
      await _draft.inFlight;
      if (!mounted) return;
      if (!_draft.dirty && !_draft.sending) Navigator.of(context).pop();
      return;
    }
    if (!_draft.dirty) return;
    final choice = await _ask<_Leave>(
      'Unsaved alarm changes',
      'Save them before you leave? Saving also updates the band.',
      const [
        ('Keep editing', _Leave.keep),
        ('Discard', _Leave.discard),
        ('Save', _Leave.save),
      ],
    );
    if (!mounted || choice == null || choice == _Leave.keep) return;
    if (choice == _Leave.discard) {
      Navigator.of(context).pop();
      return;
    }
    final send = widget.onSave;
    if (send == null) return;
    final out = await _draft.save(send);
    if (!mounted) return;
    // A failure stays on screen, with its reason and Retry in the header.
    if (out != null && out.ok) Navigator.of(context).pop();
  }

  Future<T?> _ask<T>(String title, String body, List<(String, T)> options) =>
      showDialog<T>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            for (final o in options)
              TextButton(
                onPressed: () => Navigator.pop(ctx, o.$2),
                child: Text(o.$1),
              ),
          ],
        ),
      );

  // ── pickers (all edit the draft) ───────────────────────────────────────────

  Future<void> _pickDayTime(AlarmScheduleEntry day) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: day.hour, minute: day.minute),
    );
    if (picked == null || !mounted) return;
    _draft.setTime(day.weekday, picked.hour, picked.minute);
  }

  Future<T?> _choose<T>(String title, List<(T, String)> options) =>
      showDialog<T>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(title),
          children: [
            for (final o in options)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, o.$1),
                child: Text(o.$2),
              ),
          ],
        ),
      );

  List<(int, String)> get _windowOptions => [
    (0, 'Off'),
    for (
      var m = kWakeWindowStepMinutes;
      m <= kWakeWindowMaxMinutes;
      m += kWakeWindowStepMinutes
    )
      (m, '$m min before'),
  ];

  Future<void> _pickNatural(AlarmScheduleEntry day) async {
    final m = await _choose<int>('Natural Wake window', _windowOptions);
    if (m == null || !mounted) return;
    _draft.setNaturalWindow(day.weekday, m);
  }

  Future<void> _pickGradual(AlarmScheduleEntry day) async {
    final m = await _choose<int>('Gradual Wake window', _windowOptions);
    if (m == null || !mounted) return;
    _draft.setGradualWindow(day.weekday, m);
  }

  Future<void> _pickPattern(AlarmScheduleEntry day) async {
    final p = await _choose<GradualPattern>('Gradual Wake pattern', const [
      (GradualPattern.ramp, 'Ramp up'),
      (GradualPattern.steady, 'Steady'),
    ]);
    if (p == null || !mounted) return;
    _draft.setGradualPattern(day.weekday, p);
  }

  Future<void> _pickCadence(AlarmScheduleEntry day) async {
    final s = await _choose<int>('Gradual Wake cadence', [
      for (
        var s = kGradualCadenceMinSec;
        s <= kGradualCadenceMaxSec;
        s += kGradualCadenceStepSec
      )
        (s, '${s ~/ 60} min'),
    ]);
    if (s == null || !mounted) return;
    _draft.setGradualCadence(day.weekday, s);
  }

  Future<void> _acknowledge(bool enableNatural) async {
    try {
      await widget.onAcknowledgeUpgrade?.call(enableNatural);
    } catch (e) {
      if (mounted) _say('$e'.replaceFirst('Exception: ', ''));
    }
  }

  /// Run a band write and report what happened. These throw when the band is
  /// not connected, and silence would read as success.
  Future<void> _run(Future<void> Function()? action, String ok) async {
    if (action == null) return;
    try {
      await action();
      if (mounted) _say(ok);
    } catch (e) {
      if (mounted) _say('$e'.replaceFirst('Exception: ', ''));
    }
  }

  void _say(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final w = widget;
    final at = w.armedAt;
    return ListenableBuilder(
      listenable: _draft,
      builder: (c, _) {
        final week = _draft.entries;
        final anyDayEnabled = week.any((d) => d.enabled);
        return PopScope(
          // Dirty, or still talking to the band: ask before leaving.
          canPop: !_draft.dirty && !_draft.sending,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_confirmLeave());
          },
          child: Scaffold(
            backgroundColor: p.bg,
            body: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: NavBar(
                      l?.alarmNavTitle ?? 'Alarm',
                      sub:
                          l?.alarmNavSub ??
                          'The band wakes you at the set time',
                    ),
                  ),
                  _header(c, p),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                      children: [
                        if (at != null) ...[
                          Surface(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l?.alarmNextLabel ?? 'NEXT',
                                  style: F.over.copyWith(color: p.ink3),
                                ),
                                const SizedBox(height: S.x1),
                                Text(
                                  AlarmScreenView._dayAndTime(c, at),
                                  style: F.n48.copyWith(color: p.ink),
                                ),
                                Text(
                                  AlarmScreenView._whichDay(
                                    c,
                                    at,
                                    w.now ?? DateTime.now(),
                                  ),
                                  style: F.cap.copyWith(color: p.ink2),
                                ),
                              ],
                            ),
                          ),
                          if (AlarmScreenView._stateDetail(c, w.state)
                              case final detail?) ...[
                            const SizedBox(height: S.x3),
                            StatusCard(
                              AlarmScreenView._stateHeadline(c, w.state),
                              detail,
                              icon: AlarmScreenView._stateIcon(w.state),
                            ),
                          ],
                          const SizedBox(height: S.x4),
                        ],
                        // The reason is said once, here. Rows still work: edits
                        // are a draft, and a Save made offline reaches the band
                        // on the next connect.
                        if (!w.connected)
                          StatusCard(
                            l?.alarmNotConnectedTitle ??
                                'The band is not connected',
                            'You can still change the schedule. Saving keeps it '
                            'on this phone and sends it to the band when it '
                            'reconnects. Testing and cancelling need a live '
                            'connection. An alarm that is already armed '
                            'keeps running on the band.',
                            icon: LucideIcons.bluetoothOff,
                          ),
                        _dayTabs(c, week),
                        SettingsAccordion(
                          'Alarm and wake',
                          id: 'alarm_day',
                          summary: _daySummary(c, week[_wakeDay]),
                          children: _dayChildren(c, p, week),
                        ),
                        SettingsAccordion(
                          'Timeline and status',
                          id: 'alarm_timeline',
                          summary: AlarmScreenView._localizedStateLabel(
                            c,
                            w.state,
                          ),
                          children: _timelineChildren(c, p, week),
                        ),
                        const SizedBox(height: S.x4),
                        // Present always; inert and dimmed when there is nothing
                        // to test or cancel, or no band to tell.
                        Opacity(
                          opacity: w.connected && at != null
                              ? 1
                              : kDisabledOpacity,
                          child: BigButton(
                            l?.alarmTestTheBuzz ?? 'Test the buzz',
                            icon: LucideIcons.vibrate,
                            color: C.blue,
                            soft: true,
                            onTap: w.connected && at != null
                                ? () => _run(
                                    w.onTest,
                                    l?.alarmBuzzingTheBand ??
                                        'Buzzing the band',
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: S.x3),
                        Opacity(
                          opacity: w.connected && (at != null || anyDayEnabled)
                              ? 1
                              : kDisabledOpacity,
                          child: BigButton(
                            l?.alarmCancelTheAlarm ?? 'Cancel the alarm',
                            icon: LucideIcons.bellOff,
                            color: C.red,
                            soft: true,
                            onTap: w.connected && (at != null || anyDayEnabled)
                                ? () => _run(
                                    w.onCancelAlarm,
                                    l?.alarmCancelled ?? 'Alarm cancelled',
                                  )
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Save / Cancel and what the last Save did, pinned under the nav bar.
  Widget _header(BuildContext c, P p) {
    final out = _draft.outcome;
    final failed = out?.status == AlarmSaveStatus.failed;
    final retry = failed && out!.persisted && !_draft.dirty;
    final canSave = _draft.canSave && widget.onSave != null;
    final canCancel = _draft.canCancel;
    final status = _draft.sending
        ? 'Saving and sending to the band…'
        : failed
        ? out!.headline
        : _draft.dirty
        ? 'Unsaved changes. Nothing is saved or sent to the band '
              'until you save.'
        : out?.headlineFor(resent: widget.resent) ?? 'No unsaved changes';
    final tone = _draft.sending
        ? p.ink2
        : failed
        ? p.on(C.red)
        : _draft.dirty
        ? p.on(C.orange)
        : out == null
        ? p.ink3
        : p.on(C.green);
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x1, S.x4, S.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, style: F.cap.copyWith(color: tone)),
          const SizedBox(height: S.x2),
          Row(
            children: [
              Expanded(
                child: Opacity(
                  opacity: canCancel ? 1 : kDisabledOpacity,
                  child: BigButton(
                    'Cancel',
                    color: C.blue,
                    soft: true,
                    onTap: canCancel ? _draft.discard : null,
                  ),
                ),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Opacity(
                  opacity: canSave ? 1 : kDisabledOpacity,
                  child: BigButton(
                    retry ? 'Retry' : 'Save',
                    color: C.blue,
                    onTap: canSave ? () => _save() : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Day tabs and the two accordions ────────────────────────────────────────

  /// The weekday picker: the app's SubTabs, one tab per day in weekday order,
  /// so a tab's index is its weekday. A day that is off is drawn off but stays
  /// selectable, since its settings are still editable.
  Widget _dayTabs(BuildContext c, List<AlarmScheduleEntry> week) => Padding(
    padding: const EdgeInsets.only(top: S.x1),
    child: SubTabs(
      [for (final d in week) AlarmScreenView._weekdayLabel(c, d.weekday)],
      _wakeDay,
      (i) => setState(() => _wakeDay = i),
      color: C.blue,
      dense: true,
      muted: {
        for (final d in week)
          if (!d.enabled) d.weekday,
      },
      itemKeys: [for (final d in week) ValueKey('wake-day-${d.weekday}')],
      semanticLabels: [
        for (final d in week)
          'Edit wake settings for ${AlarmScreenView._weekdayLabel(c, d.weekday)}',
      ],
    ),
  );

  String _daySummary(BuildContext c, AlarmScheduleEntry day) {
    final label = AlarmScreenView._weekdayLabel(c, day.weekday);
    return day.enabled
        ? '$label: on at ${AlarmScreenView._hhmmOf(day.hour, day.minute)}'
        : '$label: off';
  }

  /// Copies the selected day's settings onto every day of the draft. Still a
  /// draft edit: nothing is sent until Save.
  void _applyToWeek() {
    _draft.applyToWeek(_wakeDay);
    _say('Applied to every day. Save to send it to the band.');
  }

  List<Widget> _dayChildren(
    BuildContext c,
    P p,
    List<AlarmScheduleEntry> week,
  ) {
    final w = widget;
    final l = AppLocalizations.of(c);
    final day = week[_wakeDay];
    final dayOn = day.enabled;
    final naturalOk = dayOn && w.hasExpectedSleep && !w.upgradePending;
    final gradualOn = day.gradualWindowMinutes > 0;
    final uniform = _draft.weekMatches(_wakeDay);

    String windowValue(int m) => m == 0 ? 'Off' : '$m min';

    final String naturalSub;
    if (!w.hasExpectedSleep) {
      naturalSub = 'Set your expected sleep schedule in Settings first';
    } else if (w.upgradePending) {
      naturalSub = 'Read the explanation above first';
    } else if (!dayOn) {
      naturalSub = 'Turn this day on first';
    } else {
      naturalSub =
          'Buzzes during estimated REM sleep before your alarm. '
          'Needs the phone connected.';
    }

    return [
      if (w.upgradePending) _upgradeCard(p),
      SetRow(
        LucideIcons.calendarDays,
        C.orange,
        'Alarm',
        key: const ValueKey('alarm-day-enabled'),
        value: dayOn ? (l?.stateOn ?? 'On') : (l?.stateOff ?? 'Off'),
        chevron: false,
        onTap: () => _draft.setEnabled(day.weekday, !dayOn),
      ),
      SetRow(
        LucideIcons.clock,
        C.blue,
        l?.alarmWakeTimeRowTitle ?? 'Wake time',
        enabled: dayOn,
        value: AlarmScreenView._hhmmOf(day.hour, day.minute),
        chevron: false,
        onTap: () => _pickDayTime(day),
      ),
      if (w.naturalWakeSupported) ...[
        SetRow(
          LucideIcons.sunrise,
          C.yellow,
          'Natural Wake',
          enabled: naturalOk,
          value: windowValue(day.naturalWindowMinutes),
          sub: naturalSub,
          chevron: false,
          onTap: () => _pickNatural(day),
        ),
        SetRow(
          LucideIcons.moon,
          C.indigo,
          'Expected sleep schedule',
          value: w.expectedSleepLabel ?? 'Not set',
          chevron: false,
          enabled: w.onSetSleepSchedule != null,
          onTap: () => w.onSetSleepSchedule?.call(),
        ),
      ],
      SetRow(
        LucideIcons.sunMedium,
        C.orange,
        'Gradual Wake',
        enabled: dayOn,
        value: windowValue(day.gradualWindowMinutes),
        sub: dayOn
            ? 'Soft buzzes that build up before your alarm. '
                  'Needs the phone connected.'
            : 'Turn this day on first',
        chevron: false,
        onTap: () => _pickGradual(day),
      ),
      SetRow(
        LucideIcons.audioLines,
        C.orange,
        'Gradual pattern',
        enabled: dayOn && gradualOn,
        value: day.gradualPattern == GradualPattern.ramp ? 'Ramp up' : 'Steady',
        sub: gradualOn ? '' : 'Turn Gradual Wake on first',
        chevron: false,
        onTap: () => _pickPattern(day),
      ),
      SetRow(
        LucideIcons.timer,
        C.orange,
        'Gradual cadence',
        enabled: dayOn && gradualOn,
        value: '${day.gradualCadenceSec ~/ 60} min',
        sub: gradualOn ? '' : 'Turn Gradual Wake on first',
        chevron: false,
        onTap: () => _pickCadence(day),
      ),
      // Dimmed and inert once every day already carries these settings.
      Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Opacity(
          opacity: uniform ? kDisabledOpacity : 1,
          child: BigButton(
            'Apply to full week',
            key: const ValueKey('alarm-apply-week'),
            icon: LucideIcons.calendarCheck,
            color: C.blue,
            soft: true,
            onTap: uniform ? null : _applyToWeek,
          ),
        ),
      ),
    ];
  }

  List<Widget> _timelineChildren(
    BuildContext c,
    P p,
    List<AlarmScheduleEntry> week,
  ) {
    final w = widget;
    final at = w.armedAt;
    final day = week[_wakeDay];
    final dayOn = day.enabled;
    final label = AlarmScreenView._weekdayLabel(c, day.weekday);

    // The timeline is for the next time this weekday's alarm will ring, drawn
    // from the DRAFT so it answers what the user is looking at.
    final wakeAt = nextAlarmOccurrence([
      day.copyWith(enabled: true),
    ], w.now ?? DateTime.now())!;
    // Without an expected sleep schedule Natural Wake cannot tell a main sleep
    // from a nap and stays quiet, so the preview does not promise it.
    final shown = w.hasExpectedSleep && w.naturalWakeSupported
        ? day
        : day.copyWith(naturalWindowMinutes: 0);
    final timeline =
        w.timelineFor?.call(wakeAt, shown) ??
        WakeTimeline.compute(
          wakeAt: wakeAt,
          naturalMinutes: w.upgradePending ? 0 : shown.naturalWindowMinutes,
          gradualMinutes: shown.gradualWindowMinutes,
        );

    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Opacity(
            opacity: dayOn ? 1 : kDisabledOpacity,
            child: Text(
              'TIMELINE FOR ${label.toUpperCase()} '
              '${AlarmScreenView._hhmm(wakeAt)}',
              style: F.over.copyWith(color: p.ink3),
            ),
          ),
        ),
      ),
      for (final part in timeline.parts)
        SetRow(
          _partIcon(part.id),
          _partColor(part.id),
          _partTitle(part.id),
          enabled: dayOn,
          value: part.until == null
              ? AlarmScreenView._hhmm(part.at)
              : '${AlarmScreenView._hhmm(part.at)} to '
                    '${AlarmScreenView._hhmm(part.until!)}',
          sub: part.bandNative
              ? 'works without phone'
              : 'phone must be connected',
          chevron: false,
        ),
      SetRow(
        AlarmScreenView._stateIcon(w.state),
        AlarmScreenView._stateColor(w.state),
        'Armed state',
        value: AlarmScreenView._localizedStateLabel(c, w.state),
        chevron: false,
      ),
      SetRow(
        LucideIcons.alarmClock,
        C.blue,
        'Next alarm',
        value: at == null ? '—' : AlarmScreenView._dayAndTime(c, at),
        chevron: false,
      ),
      SetRow(
        LucideIcons.listChecks,
        C.indigo,
        'Last wake decision',
        sub: w.wakeTrace.isNotEmpty
            ? w.wakeTrace.join('\n')
            : at == null
            ? 'Nothing recorded: no alarm is armed'
            : 'Nothing recorded for this wake yet',
        chevron: false,
      ),
    ];
  }

  /// Smart Wake became Natural Wake. Shown until the user has read it.
  Widget _upgradeCard(P p) => Padding(
    padding: const EdgeInsets.only(bottom: S.x3),
    child: Surface(
      color: p.card2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Smart Wake is now Natural Wake',
            style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: S.x1),
          Text(
            'It no longer looks for light sleep. Natural Wake estimates '
            'REM sleep from the band\'s heart rate and movement, which is '
            'an estimate and not sleep staging, and buzzes during REM '
            'inside your window. Your old window carries over. It needs '
            'the phone connected. The band alarm at your wake time still '
            'always rings.',
            style: F.cap.copyWith(color: p.ink2),
          ),
          const SizedBox(height: S.x3),
          BigButton(
            'Got it',
            color: C.blue,
            onTap: () => unawaited(_acknowledge(true)),
          ),
          const SizedBox(height: S.x2),
          BigButton(
            'Keep Natural Wake off',
            color: C.blue,
            soft: true,
            onTap: () => unawaited(_acknowledge(false)),
          ),
        ],
      ),
    ),
  );

  static String _partTitle(String id) => switch (id) {
    'collection' => 'Phone starts listening',
    'natural' => 'Natural Wake window',
    'gradual' => 'Gradual Wake buzzes',
    _ => 'Band alarm',
  };

  static IconData _partIcon(String id) => switch (id) {
    'collection' => LucideIcons.radio,
    'natural' => LucideIcons.sunrise,
    'gradual' => LucideIcons.sunMedium,
    _ => LucideIcons.alarmClock,
  };

  static Color _partColor(String id) => switch (id) {
    'collection' => C.blue,
    'natural' => C.yellow,
    'gradual' => C.orange,
    _ => C.green,
  };
}
