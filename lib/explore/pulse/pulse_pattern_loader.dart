// Reads the last nights for the pulse-pattern research view, through the
// existing read seam only. No compute, no writes; the numbers are what the
// derivation already stored under `respiration.cvhr_apnea`.
// Prototype: lib/explore/pulse/.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/local_repository.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../../ui2/ui2.dart';
import 'pulse_pattern_night.dart';
import 'pulse_pattern_research_screen.dart';

/// How many of the newest derived days the view reads. Two bundle reads each.
const int kPulseNightsRead = 30;

/// The newest [kPulseNightsRead] days, newest first. Per day: the stored
/// `cvhr` envelope (`getDayLungs`) and that night's sleep hours
/// (`getDaySleepV2` `duration_min`, the read the circadian artifact uses).
/// A day with no envelope is "not analysed"; a day with no sleep duration
/// has "coverage unknown". A failed read throws; it is never an empty list.
Future<List<PulsePatternNight>> loadPulsePatternNights(
    LocalRepository repo) async {
  final days = await repo.availableDays(); // newest first
  final out = <PulsePatternNight>[];
  for (final day in days.take(kPulseNightsRead)) {
    final lungs = await repo.getDayLungs(day);
    final sleep = await repo.getDaySleepV2(day);
    final minutes = sleep['duration_min'];
    out.add(fromCvhrEnvelope(
      day,
      lungs['cvhr'],
      sleepHours: minutes is num && minutes > 0 ? minutes / 60 : null,
    ));
  }
  return out;
}

/// The Device lab's way in. Nothing is read, and nothing is drawn, unless
/// developer mode AND `Prefs.explorePulsePatterns` are on. When they are, it
/// reads once (from `didChangeDependencies`, never `build`) and shows a
/// loading state, a retryable error, or the entry; an empty list is only ever
/// an actual empty answer.
class PulsePatternResearchPanel extends StatefulWidget {
  const PulsePatternResearchPanel({
    super.key,
    required this.repo,
    this.load = loadPulsePatternNights,
  });

  /// Null when there is no repository (a golden): nothing is shown.
  final LocalRepository? repo;
  final Future<List<PulsePatternNight>> Function(LocalRepository repo) load;

  @override
  State<PulsePatternResearchPanel> createState() => _PanelState();
}

class _PanelState extends State<PulsePatternResearchPanel> {
  List<PulsePatternNight>? _nights;
  bool _failed = false;
  bool _started = false;
  int _gen = 0;

  bool _gated(BuildContext c) =>
      c.caps.has(Feature.developerMode) &&
      Prefs.getBool(Prefs.explorePulsePatterns, false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started && widget.repo != null && _gated(context)) _read();
  }

  Future<void> _read() async {
    final repo = widget.repo!;
    final gen = ++_gen;
    setState(() {
      _started = true;
      _failed = false;
      _nights = null;
    });
    try {
      final nights = await widget.load(repo);
      if (!mounted || gen != _gen) return;
      setState(() => _nights = nights);
    } catch (_) {
      if (!mounted || gen != _gen) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext c) {
    if (widget.repo == null || !_gated(c)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: _body(),
    );
  }

  Widget _body() {
    final nights = _nights;
    if (_failed) {
      return StatusCard(
        'Could not read the nights',
        'Nothing was changed. This is not an empty result.',
        icon: LucideIcons.triangleAlert,
        fix: 'Try again',
        onFix: _read,
      );
    }
    if (nights == null) return const InlineLoading();
    return PulsePatternResearchEntry(nights: nights);
  }
}
