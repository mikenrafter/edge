// alarm_slot_probe.dart — the Device lab's alarm-slot probe: can the band hold
// MORE THAN ONE alarm at once?
//
// The probe remembers the wearer's real alarm, arms alarm A (2 min out) and
// alarm B (3 min out) in their own slots, reads each slot back, watches the
// alarm events, and ALWAYS (in `finally`: success, cancel, leaving the screen,
// failure) clears its own slots and puts the real alarm back through the
// normal arm path. Never leaves a probe alarm armed.
//
// Everything that touches the band or the app is injected, so this file is
// plain Dart. Time comes from package:clock.
//
// Two things keep the probe from hurting the real alarm's bookkeeping:
//  * the probe's own alarm events (56..60) are SWALLOWED while it runs (and
//    any stamped before its restore afterwards): a fired probe alarm would
//    otherwise reach AppState's alarm handler, which treats "fired" as "the
//    user's alarm is spent" and wipes the real one;
//  * a band alarm the app does not know about is never overwritten: the probe
//    stops before arming anything.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../ble/ble_state.dart';
import '../haptics/band_queue.dart';
import 'lab_log.dart';
import 'strap_event.dart';

/// Band commands the probe reserves from the shared haptic ledger before its
/// first write: SET x2, GET x5, plus the clock sync a gen5 SET carries. Clean-up
/// writes are recorded in the ledger but never refused by it: restoring the
/// wearer's alarm outranks the budget.
const int kAlarmSlotProbeCommands = 12;

/// The probe refuses when the real alarm is this close to now (either side).
const Duration kAlarmSlotNearReal = Duration(minutes: 10);

/// An event counts for a slot when it is stamped within this many seconds of
/// the slot's armed second. A and B are 60 s apart, so the windows never
/// overlap (the nearest slot wins a tie-free match).
const int kAlarmSlotFireToleranceSec = 30;

enum AlarmSlotOutcome { multi, single, inconclusive }

/// One alarm-lifecycle event seen while the probe ran.
class AlarmSlotEvent {
  const AlarmSlotEvent({
    required this.id,
    required this.tsEpoch,
    required this.receivedAt,
  });
  final int id;
  final int tsEpoch;
  final DateTime receivedAt;
}

/// Everything the probe saw: the raw material of the verdict and the evidence
/// shown with it.
class AlarmSlotEvidence {
  AlarmSlotEvidence({required this.family});

  /// `gen4` or `gen5`.
  final String family;
  int? heldEpoch;
  AlarmSlotRead? realBefore;
  AlarmSlotWrite? armA, armB;
  AlarmSlotRead? readA, readB;
  AlarmSlotRead? afterRestore;
  final List<AlarmSlotEvent> events = <AlarmSlotEvent>[];

  /// What the wearer ticked ("felt A" / "felt B"); null = not answered.
  bool? feltA, feltB;

  /// The watch ran to its end (not cancelled, not failed).
  bool watched = false;

  /// Null: there was no real alarm to restore.
  bool? restoreOk;

  bool get gen5 => family == 'gen5';
}

class AlarmSlotVerdict {
  const AlarmSlotVerdict(this.outcome, this.headline, this.evidence);
  final AlarmSlotOutcome outcome;

  /// "The band holds 2 alarms at once" / "Only one alarm is kept (...)" /
  /// "Inconclusive: ...".
  final String headline;

  /// The raw evidence, one line each.
  final List<String> evidence;
}

String _two(int v) => v.toString().padLeft(2, '0');
String _hhmm(int epochSec) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  return '${_two(t.hour)}:${_two(t.minute)}';
}

String _hms(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

String _slotName(int slot) => slot == 0 ? 'A' : 'B';

/// Whether [e] is an alarm EXECUTED event (57 strap-driven, 58 app-driven)
/// stamped at [w]'s armed second, and no other slot's armed second is nearer.
bool _firedFor(AlarmSlotEvidence ev, AlarmSlotEvent e, int slot) {
  if (e.id != AlarmConfirmation.kEvtStrapExecuted &&
      e.id != AlarmConfirmation.kEvtAppExecuted) {
    return false;
  }
  final a = ev.armA, b = ev.armB;
  if (a == null || b == null) return false;
  final dA = (e.tsEpoch - a.strapSec).abs();
  final dB = (e.tsEpoch - b.strapSec).abs();
  final nearest = dA <= dB ? 0 : 1;
  final d = nearest == 0 ? dA : dB;
  return nearest == slot && d <= kAlarmSlotFireToleranceSec;
}

String _writeLine(int slot, AlarmSlotWrite? w, bool gen5) {
  final id = gen5 ? 'gen5 id ${AlarmPayloads.gen5Slot + slot}' : 'gen4 index $slot';
  if (w == null) return 'Alarm ${_slotName(slot)} ($id): never armed.';
  final head = 'Alarm ${_slotName(slot)} ($id): wall epoch ${w.wallSec}, '
      'strap epoch ${w.strapSec},';
  if (!w.written) return '$head the write never reached the band.';
  if (!w.answered) return '$head sent, no reply (unconfirmed).';
  final status = '(result ${w.resultStatus}, alarm_status ${w.alarmStatus} '
      '${w.alarmStatusName ?? '-'})';
  return '$head ${w.rejected ? 'REFUSED' : 'accepted'} $status.';
}

String _readLine(String label, AlarmSlotRead? r) {
  if (r == null) return '$label: not read.';
  if (!r.answered) return '$label: no reply.';
  final e = r.epoch;
  return '$label: ${e == null ? 'no epoch' : 'epoch $e'}'
      '${r.active == null ? '' : ', active ${r.active}'}.';
}

List<String> _evidenceLines(AlarmSlotEvidence ev) {
  final gen5 = ev.gen5;
  final lines = <String>[
    'Band family: ${ev.family}'
        '${gen5 ? ' (alarm ids 1 and 2)' : ' (rich-form indices 0 and 1)'}.',
    if (ev.heldEpoch != null)
      'Your alarm, as the app holds it: epoch ${ev.heldEpoch} '
          '(${_hhmm(ev.heldEpoch!)}).'
    else
      'Your alarm, as the app holds it: none.',
    if (ev.realBefore != null) _readLine('Band readback before', ev.realBefore),
    _writeLine(0, ev.armA, gen5),
    _writeLine(1, ev.armB, gen5),
    if (gen5) ...[
      _readLine('Readback A (id 1)', ev.readA),
      _readLine('Readback B (id 2)', ev.readB),
    ] else
      _readLine('Readback (gen4 has no index operand: it names one alarm)',
          ev.readA),
  ];
  for (final e in ev.events) {
    final slot = _firedFor(ev, e, 0)
        ? ' - matches A'
        : _firedFor(ev, e, 1)
            ? ' - matches B'
            : '';
    lines.add('Event ${e.id} at strap epoch ${e.tsEpoch}, received '
        '${_hms(e.receivedAt)}$slot.');
  }
  if (ev.events.isEmpty) lines.add('No alarm events were seen.');
  lines.add('Felt A: ${_felt(ev.feltA)}. Felt B: ${_felt(ev.feltB)}.');
  if (ev.afterRestore != null) {
    lines.add(_readLine('Band readback after the restore', ev.afterRestore));
  }
  if (ev.restoreOk == true) {
    lines.add('Your alarm was restored.');
  } else if (ev.restoreOk == false) {
    lines.add('Your alarm was NOT restored: check the Alarm screen and save '
        'it again.');
  }
  return lines;
}

String _felt(bool? v) => v == null ? 'not answered' : (v ? 'yes' : 'no');

/// The verdict from [ev]. Pure.
///
/// Both alarms must have been taken (armed and not refused). Then, in order:
///  * both fired (an event 57/58 at the slot's second, or ticked as felt):
///    the band holds 2 alarms, whatever the readback said;
///  * gen5 readbacks by id show both stored: 2 alarms, unless the watch ended
///    with exactly one of them having fired (a conflict: inconclusive);
///  * gen5 id 1 no longer reads A while id 2 reads B: one alarm, B replaced A,
///    unless A fired (conflict: inconclusive);
///  * no usable readback (gen4 has no index operand; or no reply): B fired
///    and A is positively absent (an event saw B and none saw A, or A was
///    ticked "no") after the full watch: one alarm.
/// Anything else is inconclusive. B refused by the band is one alarm.
AlarmSlotVerdict classifyAlarmSlots(AlarmSlotEvidence ev) {
  final lines = _evidenceLines(ev);
  AlarmSlotVerdict done(AlarmSlotOutcome o, String h) =>
      AlarmSlotVerdict(o, h, lines);
  AlarmSlotVerdict unclear(String why) =>
      done(AlarmSlotOutcome.inconclusive, 'Inconclusive: $why');

  final a = ev.armA, b = ev.armB;
  if (a == null || !a.written || a.rejected) {
    return unclear(a == null
        ? 'alarm A was never armed'
        : !a.written
            ? 'alarm A never reached the band'
            : 'the band refused alarm A');
  }
  if (b == null) return unclear('alarm B was never armed');
  if (!b.written) return unclear('alarm B never reached the band');
  if (b.rejected) {
    return done(AlarmSlotOutcome.single,
        'Only one alarm is kept (the band refused B)');
  }

  bool matches(AlarmSlotRead? r, AlarmSlotWrite w) =>
      r != null && r.answered && r.epoch == w.strapSec && r.active != false;
  bool answered(AlarmSlotRead? r) => r != null && r.answered;

  final eventFiredA = ev.events.any((e) => _firedFor(ev, e, 0));
  final eventFiredB = ev.events.any((e) => _firedFor(ev, e, 1));
  final firedA = eventFiredA || ev.feltA == true;
  final firedB = eventFiredB || ev.feltB == true;
  const multi = 'The band holds 2 alarms at once';
  const replaced = 'Only one alarm is kept (B replaced A)';

  if (firedA && firedB) return done(AlarmSlotOutcome.multi, multi);

  final bothStored = ev.gen5 && matches(ev.readA, a) && matches(ev.readB, b);
  if (bothStored) {
    if (ev.watched && firedA != firedB) {
      return unclear('both alarms read back as stored, but only one fired');
    }
    return done(AlarmSlotOutcome.multi, multi);
  }

  final bReplacedA = ev.gen5 &&
      answered(ev.readA) &&
      matches(ev.readB, b) &&
      !matches(ev.readA, a);
  if (bReplacedA) {
    if (firedA) {
      return unclear('A fired although the readback says B replaced it');
    }
    return done(AlarmSlotOutcome.single, replaced);
  }

  final aAbsent = !firedA && (ev.feltA == false || eventFiredB);
  if (ev.watched && firedB && aAbsent) {
    return done(AlarmSlotOutcome.single, replaced);
  }
  return unclear(ev.watched
      ? 'no per-slot readback and not both alarms fired'
      : 'the watch did not run to its end');
}

/// Runs the probe and holds what its card shows.
class AlarmSlotProbeRunner extends ChangeNotifier {
  AlarmSlotProbeRunner({
    required this.lab,
    required this.family,
    required this.developerMode,
    required this.isConnected,
    required this.heldEpoch,
    required this.armBusy,
    required this.arm,
    required this.read,
    required this.clear,
    required this.restore,
    required this.log,
    this.ledger,
    this.runExclusive,
    this.leadA = const Duration(minutes: 2),
    this.leadB = const Duration(minutes: 3),
    this.settle = const Duration(seconds: 60),
  });

  final DeviceLabLog lab;

  /// `gen4`, `gen5`, or null while the link has not identified itself.
  final String? Function() family;
  final bool Function() developerMode;
  final bool Function() isConnected;

  /// The alarm the app holds (epoch seconds), null for none.
  final int? Function() heldEpoch;

  /// A real arm pass is in flight.
  final bool Function() armBusy;

  /// SET_ALARM for probe [slot] (0 = A, 1 = B) at [when].
  final Future<AlarmSlotWrite> Function(int slot, DateTime when) arm;
  final Future<AlarmSlotRead> Function(int slot) read;

  /// Clear probe [slot]. gen4 has no index: any slot sends the one disable.
  final Future<bool> Function(int slot) clear;

  /// Put the real alarm [epoch] back through the normal arm path.
  final Future<bool> Function(int epoch) restore;

  /// The dev log (always-on `[alarm]` lines).
  final void Function(String line) log;

  /// The shared haptic ledger (see [kAlarmSlotProbeCommands]).
  final BandCommandLedger? ledger;

  /// Runs the body alone on the band and clear of a real arm pass; false when
  /// the band could not be had (the body never ran).
  final Future<bool> Function(Future<void> Function() body)? runExclusive;

  final Duration leadA, leadB, settle;

  bool _running = false;
  Completer<void>? _cancelSignal;
  AlarmSlotEvidence? _evidence;
  AlarmSlotVerdict? _verdict;
  bool? _restoreOk;
  bool _touched = false;
  bool _clearFailed = false;
  String? _note;
  String? _status;
  int? _cutoffSec;
  final List<String> _lines = <String>[];

  bool get running => _running;
  AlarmSlotEvidence? get evidence => _evidence;
  AlarmSlotVerdict? get verdict => _verdict;
  bool? get restoreOk => _restoreOk;

  /// The last run wrote to the band and could not confirm it left it clean: a
  /// probe slot may still be armed, or the real alarm was not put back. The
  /// app keeps its pending-restore marker until a later arm pass fixes it.
  bool get needsRecovery => _touched && (_restoreOk == false || _clearFailed);

  /// One line about why the probe did not start, or what it is doing.
  String? get note => _note;
  String? get status => _status;
  List<String> get lines => List.unmodifiable(_lines);

  /// Why the probe cannot start now; null when it can.
  String? get blockedReason {
    if (!developerMode()) return 'Developer mode is off.';
    if (_running) return 'The alarm slot probe is running.';
    if (!isConnected()) return 'Connect the band first.';
    final f = family();
    if (f != 'gen4' && f != 'gen5') {
      return 'The band family is not known yet, so the probe cannot choose '
          'the right alarm form. Wait for the band to identify itself.';
    }
    if (armBusy()) {
      return 'An alarm write is in progress. Try again in a moment.';
    }
    final held = heldEpoch();
    if (held != null &&
        (held * 1000 - clock.now().millisecondsSinceEpoch).abs() <
            kAlarmSlotNearReal.inMilliseconds) {
      return 'Your alarm (${_hhmm(held)}) is within 10 minutes of now. Try '
          'the probe later, so it cannot get in the way.';
    }
    if (ledger != null &&
        ledger!.commandsLeft(clock.now()) < kAlarmSlotProbeCommands) {
      return 'The band is resting (30 commands per 2 minutes). Try again in '
          'a moment.';
    }
    return null;
  }

  /// Run the probe. Does nothing (and says why in [note]) when
  /// [blockedReason] is set.
  Future<void> run() async {
    final why = blockedReason;
    if (why != null) {
      _say(why);
      return;
    }
    final room = ledger?.reserve(kAlarmSlotProbeCommands, clock.now());
    if (ledger != null && room == null) {
      _say('The band is resting (30 commands per 2 minutes). Try again in a '
          'moment.');
      return;
    }
    final held = heldEpoch();
    _running = true;
    _cancelSignal = Completer<void>();
    _evidence = AlarmSlotEvidence(family: family()!)..heldEpoch = held;
    _verdict = null;
    _restoreOk = null;
    _touched = false;
    _clearFailed = false;
    _note = null;
    _status = 'Starting';
    _lines.clear();
    lab.beginSession(
      method: 'Alarm slot probe',
      settings: 'A at +${leadA.inMinutes} min, B at +${leadB.inMinutes} min, '
          'band ${_evidence!.family}',
      tapAt: DateTime.now(),
    );
    notifyListeners();
    var bodyRan = false;
    try {
      Future<void> body() {
        bodyRan = true;
        return _session(held, room);
      }

      final slot = runExclusive;
      if (slot == null) {
        await body();
      } else if (!await slot(body)) {
        _note = 'The band is busy. Try the alarm slot probe again in a '
            'moment.';
      }
    } catch (e) {
      // _session handles its own failures; this is the last net, so the
      // running flag can never stick (§4.3).
      _step('probe failed: $e');
    } finally {
      room?.release();
      _running = false;
      _status = null;
      lab.endSession(
        result: _verdict?.headline ?? (bodyRan ? 'stopped' : 'not run'),
      );
      notifyListeners();
    }
  }

  /// Stop the probe now: the run clears its slots and restores the real alarm,
  /// then ends. Also what leaving the screen does. Safe to call twice, or
  /// when nothing runs.
  void cancel() {
    if (!_running) return;
    final c = _cancelSignal;
    if (c == null || c.isCompleted) return;
    _step('stopped: restoring your alarm now');
    c.complete();
  }

  /// The wearer's "felt A / felt B". Moves the verdict once there is one.
  void markFelt(int slot, bool? felt) {
    final ev = _evidence;
    if (ev == null) return;
    if (slot == 0) {
      ev.feltA = felt;
    } else {
      ev.feltB = felt;
    }
    if (_verdict != null) _verdict = classifyAlarmSlots(ev);
    notifyListeners();
  }

  /// A live band event. Alarm events during the run become evidence.
  void onBandEvent(StrapEvent e) {
    final ev = _evidence;
    if (!_running || ev == null) return;
    const watched = {56, 57, 58, 59, 60, 100};
    if (!watched.contains(e.eventId)) return;
    ev.events.add(AlarmSlotEvent(
        id: e.eventId, tsEpoch: e.tsEpoch, receivedAt: e.receivedAt));
    _step('event ${e.eventId} at strap epoch ${e.tsEpoch}');
  }

  /// Whether AppState must NOT hand [e] to its alarm handler: events 56..60
  /// while the probe runs, and any stamped before the probe's restore began
  /// (the probe alarms' own lifecycle, arriving late). A fired probe alarm
  /// reaching that handler would wipe the wearer's real alarm.
  bool swallowsEvent(StrapEvent e) {
    if (e.eventId < 56 || e.eventId > 60) return false;
    if (_running) return true;
    final c = _cutoffSec;
    return c != null && e.tsEpoch < c;
  }

  // ── the run ────────────────────────────────────────────────────────────────

  bool get _cancelled => _cancelSignal?.isCompleted ?? false;

  Future<void> _session(int? held, BandReservation? room) async {
    final ev = _evidence!;
    var touched = false;
    try {
      _step('remembered your alarm: the app holds '
          '${held == null ? 'none' : '${_hhmm(held)} (epoch $held)'}');
      ev.realBefore = await _read(0, 'before', room);
      final onBand = ev.realBefore?.epoch;
      if (held == null &&
          onBand != null &&
          ev.realBefore?.active != false &&
          onBand * 1000 > clock.now().millisecondsSinceEpoch) {
        _note = 'The band holds an alarm the app does not know about '
            '(${_hhmm(onBand)}). The probe would overwrite it, so it did '
            'not run. Save your alarm in the app first.';
        _step(_note!);
        return;
      }
      final t0 = clock.now();
      // Set before the write: a write that errors midway may still have
      // landed, and the clean-up must run for it.
      touched = _touched = true;
      ev.armA = await _arm(0, t0.add(leadA), room);
      final aTaken = ev.armA!.written && !ev.armA!.rejected;
      if (aTaken && !_cancelled) ev.armB = await _arm(1, t0.add(leadB), room);
      final bTaken = ev.armB != null && ev.armB!.written && !ev.armB!.rejected;
      if (aTaken && bTaken && !_cancelled) {
        ev.readA = await _read(0, 'A', room);
        if (ev.gen5) ev.readB = await _read(1, 'B', room);
      }
      if (aTaken && bTaken && !_cancelled) {
        await _watch(t0.add(leadB).add(settle));
      }
    } catch (e) {
      _step('probe error: $e');
    } finally {
      if (touched) await _cleanup(held);
      if (touched) {
        _verdict = classifyAlarmSlots(ev);
        _step('result: ${_verdict!.headline}');
      }
    }
  }

  Future<void> _watch(DateTime until) async {
    final ev = _evidence!;
    final left = until.difference(clock.now());
    _status = 'Waiting for the alarms (watching until ${_hms(until)})';
    notifyListeners();
    if (left <= Duration.zero) {
      ev.watched = true;
      return;
    }
    try {
      await _cancelSignal!.future.timeout(left);
    } on TimeoutException {
      ev.watched = true; // ran to its end
    }
  }

  Future<AlarmSlotWrite> _arm(int slot, DateTime when, BandReservation? room) async {
    _status = 'Arming alarm ${_slotName(slot)}';
    notifyListeners();
    _spend(room);
    final w = await arm(slot, when);
    _step('armed ${_slotName(slot)} for ${_hms(when)}: '
        '${!w.written ? 'NOT WRITTEN' : !w.answered ? 'sent, no reply' : w.rejected ? 'REFUSED' : 'accepted'}'
        ' (alarm_status ${w.alarmStatus} ${w.alarmStatusName ?? '-'}, '
        'strap epoch ${w.strapSec})');
    return w;
  }

  /// A readback. A [room] of null is the clean-up phase: recorded, never
  /// refused. A throw is an unanswered read, never a failed run.
  Future<AlarmSlotRead> _read(int slot, String what, BandReservation? room,
      {bool cleanup = false}) async {
    try {
      if (cleanup) {
        ledger?.record(1, clock.now());
      } else {
        _spend(room);
      }
      final r = await read(slot);
      _step('readback $what: ${r.answered ? 'epoch ${r.epoch}'
          '${r.active == null ? '' : ', active ${r.active}'}' : 'no reply'}');
      return r;
    } catch (e) {
      _step('readback $what failed: $e');
      return const AlarmSlotRead.silent();
    }
  }

  void _spend(BandReservation? room) {
    if (room != null && !room.take(clock.now())) {
      throw StateError('the haptic budget reserved for the probe is used up');
    }
  }

  /// Clear the probe's slots and put the real alarm back. Every step is
  /// guarded on its own: one failing must not skip the next.
  Future<void> _cleanup(int? held) async {
    final ev = _evidence!;
    _status = 'Restoring your alarm';
    notifyListeners();
    // Events stamped before now (strap frame) are the probe's.
    _cutoffSec = clock.now().millisecondsSinceEpoch ~/ 1000 -
        (ev.armA?.driftSec ?? 0);
    // B always. A shares the real slot (gen5 id 1), which the restore
    // overwrites, unless there is no real alarm to put there. gen4's disable
    // has no index: one send clears what it clears.
    final slots = [1, if (ev.gen5 && held == null) 0];
    for (final s in slots) {
      try {
        ledger?.record(1, clock.now());
        final ok = await clear(s);
        if (!ok) _clearFailed = true;
        _step('cleared probe slot ${_slotName(s)}: ${ok ? 'sent' : 'FAILED'}');
      } catch (e) {
        _clearFailed = true;
        _step('clearing probe slot ${_slotName(s)} FAILED: $e');
      }
    }
    if (held != null) {
      var ok = false;
      try {
        ok = await restore(held);
      } catch (e) {
        _step('restoring your alarm threw: $e');
      }
      _restoreOk = ev.restoreOk = ok;
      _step(ok
          ? 'restored your alarm (${_hhmm(held)}, epoch $held)'
          : 'your alarm was NOT restored. The band may hold a probe alarm '
              'or none: open the Alarm screen and save it again.');
    }
    ev.afterRestore = await _read(0, 'after the restore', null, cleanup: true);
    if (ev.gen5) {
      await _read(1, 'slot B after the clear', null, cleanup: true);
    }
  }

  void _say(String line) {
    _note = line;
    _step(line, notify: false);
    notifyListeners();
  }

  void _step(String line, {bool notify = true}) {
    _lines.add(line);
    lab.addStep(line);
    log('[alarm] probe: $line');
    if (notify) notifyListeners();
  }
}
