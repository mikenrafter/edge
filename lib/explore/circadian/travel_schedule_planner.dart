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
TravelPlan plan(TravelInput input) => throw UnimplementedError();
