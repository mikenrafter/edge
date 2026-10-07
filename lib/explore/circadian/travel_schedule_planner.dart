// travel_schedule_planner.dart — a schedule-based travel plan from explicit
// user inputs. Output 3 of 3 of the circadian explore prototype.
//
// It reads NO physiology: only the sleep times the person typed, two IANA zones
// and a departure date. Per day it gives a shifted target sleep/wake, moving at
// most 1 h/day earlier (advance) or 1.5 h/day later (delay), starting up to 3
// days before departure. The rates are an ASSUMPTION taken from Eastman &
// Burgess 2009, doi 10.1016/j.jsmc.2009.02.006; they are not measured for this
// person.
//
// Light hints are coarse text only ("seek morning light", "seek evening
// light", "avoid bright light"), tied to the planned schedule and never a clock
// window. Light can advance or delay the clock depending on its biological
// timing (Khalsa et al. 2003, doi 10.1113/jphysiol.2003.040477), so when the
// shift direction is ambiguous (|shift| >= [kAmbiguousShiftHours]) the hints
// are suppressed with a reason. No medication or melatonin dosing, ever.
//
// Conventions:
//  * Clock values are wall-clock Durations since local midnight, [0, 24 h).
//  * A day's night is the one starting the evening of [TravelDay.date]: the
//    first moment at/after 12:00 local on that date whose wall clock is
//    targetOnset; wake is the first moment after that with wall clock
//    targetWake. Days before the departure date are in originTz, from the
//    departure date on in destTz.
//  * Shift is measured in real elapsed time against the habitual wall-clock
//    chain in originTz, so a DST change in either zone is handled by the tz
//    database, never by adding 24 h.
//  * Zone offsets are read on the departure date. The caller must have run
//    tz.initializeTimeZones() (NotificationService does at app start).
//
// PROTOTYPE: pure edge orchestration; the phase science stays in analytics.

import 'dart:math' as math;

import 'package:timezone/timezone.dart' as tz;

class TravelInput {
  const TravelInput({
    required this.habitualOnset,
    required this.habitualWake,
    required this.originTz,
    required this.destTz,
    required this.departureLocalDate,
    this.desiredOnset,
    this.desiredWake,
  });

  /// Usual sleep onset / wake, since local midnight in the origin zone.
  final Duration habitualOnset;
  final Duration habitualWake;

  /// IANA names, e.g. 'America/New_York'.
  final String originTz;
  final String destTz;

  /// Departure calendar date in the origin zone (only y/m/d is read).
  final DateTime departureLocalDate;

  /// Wanted sleep onset / wake in the destination zone; null = the habitual
  /// wall-clock times.
  final Duration? desiredOnset;
  final Duration? desiredWake;
}

const Duration kMaxAdvanceStepPerDay = Duration(hours: 1);
const Duration kMaxDelayStepPerDay = Duration(minutes: 90);
const int kMaxPreDepartureDays = 3;
const int kAmbiguousShiftHours = 10;

class TravelDay {
  const TravelDay({
    required this.date,
    required this.tz,
    required this.targetOnset,
    required this.targetWake,
    this.lightHint,
  });

  /// Calendar date (midnight, y/m/d) in [tz].
  final DateTime date;
  final String tz;
  final Duration targetOnset;
  final Duration targetWake;

  /// Coarse light text, or null.
  final String? lightHint;
}

class TravelPlan {
  const TravelPlan({
    required this.days,
    required this.shiftHours,
    this.lightSuppressedReason,
    required this.assumptions,
  });

  final List<TravelDay> days;

  /// Whole hours between the zones on the departure date, signed, in
  /// [-12, 12]: positive = advance (eastward), negative = delay (westward).
  final int shiftHours;

  /// Why light hints are absent ('no time-zone change', or an ambiguous
  /// direction); null when hints are given.
  final String? lightSuppressedReason;

  /// Plain statements of what this plan assumes (rates and their source).
  final List<String> assumptions;
}

/// Throws [ArgumentError] for an unknown IANA name. Same offset on the
/// departure date: an empty plan, shiftHours 0, reason 'no time-zone change'.
TravelPlan plan(TravelInput input) {
  final origin = _location(input.originTz);
  final dest = _location(input.destTz);
  final dep = input.departureLocalDate;

  // Offsets are read at noon on the departure date, clear of any 02:00 change.
  final oOff = _offsetMinutes(origin, dep);
  final dOff = _offsetMinutes(dest, dep);
  final zone = dOff - oOff;
  if (zone == 0) return _noChange();
  final zoneHours = (_wrap(zone, 720, zone) / 60).round();

  // Total shift per series, in minutes, + = earlier. A series is the sleep
  // onset or the wake time: (usual - wanted) on the clock, plus the zone gap.
  final wantOnset = input.desiredOnset ?? input.habitualOnset;
  final wantWake = input.desiredWake ?? input.habitualWake;
  final needOnset =
      _wrap(_minutes(input.habitualOnset) - _minutes(wantOnset) + zone, 720, zone);
  final needWake =
      _wrap(_minutes(input.habitualWake) - _minutes(wantWake) + zone, 720, zone);
  if (needOnset == 0 && needWake == 0) return _noChange();

  final stepsOnset = _stepsFor(needOnset);
  final stepsWake = _stepsFor(needWake);
  final steps = math.max(stepsOnset, stepsWake);

  // Start up to three days ahead, the first step on the first plan day. A plan
  // that is done before departure still runs on to the departure date.
  final lead = math.min(kMaxPreDepartureDays, steps);
  final lastIndex = math.max(steps, lead + 1); // day k of the last plan day
  final days = <TravelDay>[];
  final ambiguous =
      math.max(zoneHours.abs(), (needOnset.abs() / 60).round()) >=
          kAmbiguousShiftHours;
  for (var k = 1; k <= lastIndex; k++) {
    final date = DateTime(dep.year, dep.month, dep.day - lead + k - 1);
    final before = k <= lead;
    final loc = before ? origin : dest;
    final shiftOnset = _shiftAt(needOnset, k);
    final shiftWake = _shiftAt(needWake, k);

    // The habitual night in the origin zone on this date, as real instants.
    final startH = _nightStart(origin, date, input.habitualOnset);
    final wakeH = _wakeAfter(startH, input.habitualWake);

    final Duration onsetClock, wakeClock;
    if (k >= stepsOnset && !before) {
      onsetClock = wantOnset;
    } else {
      onsetClock = _clockIn(loc, startH.subtract(Duration(minutes: shiftOnset)));
    }
    if (k >= stepsWake && !before) {
      wakeClock = wantWake;
    } else {
      wakeClock = _clockIn(loc, wakeH.subtract(Duration(minutes: shiftWake)));
    }

    String? hint;
    if (!ambiguous && k <= stepsOnset) {
      hint = needOnset > 0 ? _morningLight : _eveningLight;
    }
    days.add(TravelDay(
      date: date,
      tz: before ? input.originTz : input.destTz,
      targetOnset: onsetClock,
      targetWake: wakeClock,
      lightHint: hint,
    ));
  }

  return TravelPlan(
    days: days,
    shiftHours: zoneHours,
    lightSuppressedReason: ambiguous ? _ambiguousReason : null,
    assumptions: const [
      'Assumption: sleep moves earlier by up to 1 hour per day '
          '(Eastman & Burgess 2009, doi 10.1016/j.jsmc.2009.02.006).',
      'Assumption: sleep moves later by up to 1.5 hours per day '
          '(Eastman & Burgess 2009).',
      'These rates are assumed for anyone, not measured for you.',
      'The plan reads only the sleep times and time zones entered here, no '
          'body data. Zone offsets are read on the departure date.',
    ],
  );
}

const String _morningLight = 'seek morning light';
const String _eveningLight = 'seek evening light';
const String _ambiguousReason =
    'With a shift of $kAmbiguousShiftHours hours or more, light can move '
    'sleep timing either way depending on when it arrives, so no light advice '
    'is given.';

TravelPlan _noChange() => const TravelPlan(
      days: [],
      shiftHours: 0,
      lightSuppressedReason: 'no time-zone change',
      assumptions: [],
    );

tz.Location _location(String name) {
  try {
    return tz.getLocation(name);
  } on tz.LocationNotFoundException {
    throw ArgumentError.value(name, 'time zone', 'unknown IANA time zone');
  }
}

int _offsetMinutes(tz.Location loc, DateTime date) =>
    tz.TZDateTime(loc, date.year, date.month, date.day, 12)
        .timeZoneOffset
        .inMinutes;

int _minutes(Duration d) => d.inMinutes;

/// [x] minutes folded into [-720, 720]. At exactly +-720 the sign of [tie]
/// decides which way round it goes.
int _wrap(int x, int half, int tie) {
  var n = ((x % 1440) + 1440) % 1440;
  if (n > half) n -= 1440;
  if (n == half) n = tie < 0 ? -half : half;
  return n;
}

/// Days of stepping a total shift of [need] minutes takes at the pace limit.
int _stepsFor(int need) {
  if (need == 0) return 0;
  final rate = (need > 0 ? kMaxAdvanceStepPerDay : kMaxDelayStepPerDay).inMinutes;
  return (need.abs() + rate - 1) ~/ rate;
}

/// The shift, in minutes, after step [k] (1-based): full pace, then the rest.
int _shiftAt(int need, int k) {
  if (need == 0) return 0;
  final rate = (need > 0 ? kMaxAdvanceStepPerDay : kMaxDelayStepPerDay).inMinutes;
  final moved = math.min(need.abs(), k * rate);
  return need > 0 ? moved : -moved;
}

/// First moment at/after 12:00 local on [date] whose wall clock is [clock].
tz.TZDateTime _nightStart(tz.Location loc, DateTime date, Duration clock) {
  final next = clock < const Duration(hours: 12) ? 1 : 0;
  return tz.TZDateTime(loc, date.year, date.month, date.day + next,
      clock.inHours, clock.inMinutes % 60);
}

/// First moment after [onset] whose wall clock is [clock].
tz.TZDateTime _wakeAfter(tz.TZDateTime onset, Duration clock) {
  var w = tz.TZDateTime(onset.location, onset.year, onset.month, onset.day,
      clock.inHours, clock.inMinutes % 60);
  if (!w.isAfter(onset)) {
    w = tz.TZDateTime(onset.location, onset.year, onset.month, onset.day + 1,
        clock.inHours, clock.inMinutes % 60);
  }
  return w;
}

/// The wall clock of the instant [t] in [loc], since local midnight.
Duration _clockIn(tz.Location loc, DateTime t) {
  final l = tz.TZDateTime.from(t, loc);
  return Duration(hours: l.hour, minutes: l.minute);
}
