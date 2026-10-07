// circadian_explore_screen.dart — the developer-only explore surface for the
// three circadian outputs. Shown only with Feature.developerMode AND the
// default-off Prefs.exploreCircadian.
//
// Sections: "Your recorded daily rhythm" (sleep timing + experimental HR
// rhythm, with a rejection spelled out in words and no clock time when the fit
// is refused) and, when a plan is given, "Travel schedule based on your usual
// sleep times". Never says "internal clock", melatonin or doses.
//
// [CircadianExploreScreen] is the body only (a Column, no Scaffold) so it sits
// in any scroll view. [CircadianExploreEntry] is the gated tile; it opens a
// page with the body and the travel plan form ([TravelPlanForm]).

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../../ui2/ui2.dart';
import 'hr_rhythm_fit.dart';
import 'sleep_timing_summary.dart';
import 'travel_plan_form.dart';
import 'travel_schedule_planner.dart';

const String kRhythmSectionTitle = 'Your recorded daily rhythm';
const String kTravelSectionTitle =
    'Travel schedule based on your usual sleep times';
const String kExperimentalNote = 'Experimental — fit quality is not accuracy';

class CircadianExploreScreen extends StatelessWidget {
  const CircadianExploreScreen({
    super.key,
    required this.summary,
    required this.rhythm,
    this.plan,
  });

  final SleepTimingSummary summary;
  final HrRhythm rhythm;
  final TravelPlan? plan;

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Section(
          kRhythmSectionTitle,
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._sleepTiming(p),
                const SizedBox(height: S.x4),
                ..._hrRhythm(p),
                const SizedBox(height: S.x3),
                Text(
                  '$kExperimentalNote. Nothing here has been checked against '
                  'a reference measurement.',
                  style: F.cap.copyWith(color: p.ink2, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        if (plan != null)
          Section(
            kTravelSectionTitle,
            Surface(child: _travel(p, plan!)),
          ),
      ],
    );
  }

  List<Widget> _sleepTiming(P p) {
    final s = summary;
    final spread = s.onsetSpread;
    return [
      Text('Sleep timing', style: F.body.copyWith(color: p.ink)),
      _row(p, 'Usual sleep onset', _clock(s.meanOnsetClock)),
      _row(p, 'Usual wake', _clock(s.meanWakeClock)),
      _row(p, 'Mid-sleep', _clock(s.midSleepClock)),
      _row(p, 'Onset varies by',
          spread == null ? _dash : '${spread.inMinutes} min'),
      Text(
        '${s.nights} ${s.nights == 1 ? 'night' : 'nights'} recorded'
        '${s.meanOnsetClock == null ? ', and three are needed' : ''}.',
        style: F.cap.copyWith(color: p.ink2),
      ),
    ];
  }

  List<Widget> _hrRhythm(P p) {
    final r = rhythm;
    final why = r.rejection;
    return [
      Text('Heart rate rhythm', style: F.body.copyWith(color: p.ink)),
      if (why != null)
        Padding(
          padding: const EdgeInsets.only(top: S.x1),
          child: Text(_rejectionText(why),
              style: F.cap.copyWith(color: p.ink2, height: 1.4)),
        )
      else ...[
        _row(p, 'Peak', _clock(r.acrophaseClock)),
        _row(p, 'Trough', _clock(r.bathyphaseClock)),
        _row(p, 'Amplitude',
            r.amplitudeBpm == null ? _dash : '${r.amplitudeBpm!.toStringAsFixed(1)} bpm'),
        _row(p, 'Mean',
            r.mesorBpm == null ? _dash : '${r.mesorBpm!.toStringAsFixed(1)} bpm'),
        Text(
          'From ${r.daysUsed} days, ${(r.coverage * 100).round()}% of hours '
          'covered. A 24 h cosine fitted to hourly heart rate.',
          style: F.cap.copyWith(color: p.ink2, height: 1.4),
        ),
      ],
    ];
  }

  String _rejectionText(RhythmRejection why) => switch (why) {
        RhythmRejection.tooFewDays =>
          'Not enough days: at least $kMinRhythmDays days of recorded heart '
              'rate are needed.',
        RhythmRejection.lowCoverage =>
          'Too many gaps: at least $kMinRhythmDays days with '
              '$kMinCoveredHoursPerDay hours or more of recorded heart rate '
              'are needed.',
        RhythmRejection.flat =>
          'The daily swing is too flat to place a peak, so none is shown.',
        RhythmRejection.unstable =>
          'The timing was not stable from day to day, so none is shown.',
      };

  Widget _travel(P p, TravelPlan t) {
    final reason = t.lightSuppressedReason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(p, 'Time zone gap', _shiftText(t.shiftHours)),
        if (reason != null)
          Padding(
            padding: const EdgeInsets.only(top: S.x1),
            child: Text(reason, style: F.cap.copyWith(color: p.ink2, height: 1.4)),
          ),
        if (t.days.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: S.x2),
            child: Text('No schedule is needed.',
                style: F.cap.copyWith(color: p.ink2)),
          ),
        for (final d in t.days) ...[
          const SizedBox(height: S.x3),
          Text('${_date(d.date)}  ·  ${d.tz}',
              style: F.cap.copyWith(color: p.ink2)),
          Text('Sleep ${_clock(d.targetOnset)}  ·  Wake ${_clock(d.targetWake)}',
              style: F.body.copyWith(color: p.ink)),
          if (d.lightHint != null)
            Text(d.lightHint!, style: F.cap.copyWith(color: p.ink2)),
        ],
        if (t.assumptions.isNotEmpty) const SizedBox(height: S.x4),
        for (final a in t.assumptions)
          Padding(
            padding: const EdgeInsets.only(top: S.x1),
            child: Text(a, style: F.cap.copyWith(color: p.ink2, height: 1.4)),
          ),
      ],
    );
  }

  static String _shiftText(int h) => h == 0
      ? 'none'
      : '${h.abs()} h ${h > 0 ? 'east (earlier)' : 'west (later)'}';

  Widget _row(P p, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x1),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
                child: Text(label, style: F.cap.copyWith(color: p.ink2))),
            const SizedBox(width: S.x2),
            Text(value, style: F.body.copyWith(color: p.ink)),
          ],
        ),
      );
}

const String _dash = '—';

/// HH:MM, 24 h; the em dash for a clock that is not known.
String _clock(Duration? d) {
  if (d == null) return _dash;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours % 24)}:${two(d.inMinutes % 60)}';
}

String _date(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// The entry tile (key 'circadian-explore-entry'): absent unless developer mode
/// is on and Prefs.exploreCircadian is set. Tapping opens the screen.
class CircadianExploreEntry extends StatelessWidget {
  const CircadianExploreEntry({
    super.key,
    required this.summary,
    required this.rhythm,
    this.plan,
  });

  final SleepTimingSummary summary;
  final HrRhythm rhythm;
  final TravelPlan? plan;

  /// The one gate, shared with the loader that fetches the data: developer mode
  /// AND the explore pref.
  static bool shown(BuildContext context) =>
      context.caps.has(Feature.developerMode) &&
      Prefs.getBool(Prefs.exploreCircadian, false);

  @override
  Widget build(BuildContext context) {
    if (!shown(context)) return const SizedBox.shrink();
    final p = P.of(context);
    return Surface(
      key: const ValueKey('circadian-explore-entry'),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            _CircadianExplorePage(summary: summary, rhythm: rhythm, plan: plan),
      )),
      child: Row(children: [
        Icon(LucideIcons.sunMoon, size: 20, color: p.on(C.indigo)),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Circadian estimate', style: F.body.copyWith(color: p.ink)),
              Text(
                'Your recorded daily rhythm and a schedule for a trip. '
                'Experimental.',
                style: F.cap.copyWith(color: p.ink2),
              ),
            ],
          ),
        ),
        Icon(LucideIcons.chevronRight, size: 17, color: p.ink3),
      ]),
    );
  }
}

class _CircadianExplorePage extends StatefulWidget {
  const _CircadianExplorePage({
    required this.summary,
    required this.rhythm,
    this.plan,
  });
  final SleepTimingSummary summary;
  final HrRhythm rhythm;
  final TravelPlan? plan;

  @override
  State<_CircadianExplorePage> createState() => _CircadianExplorePageState();
}

class _CircadianExplorePageState extends State<_CircadianExplorePage> {
  TravelPlan? _plan;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Circadian estimate'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x6),
              children: [
                CircadianExploreScreen(
                    summary: widget.summary,
                    rhythm: widget.rhythm,
                    plan: _plan),
                Section(
                  'Plan a trip',
                  Surface(
                    child: TravelPlanForm(
                      summary: widget.summary,
                      onPlan: (t) => setState(() => _plan = t),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
