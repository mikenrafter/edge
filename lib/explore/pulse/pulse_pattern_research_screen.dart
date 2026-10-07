// Developer-only research view of repeating nighttime pulse patterns.
// Prototype: lib/explore/pulse/. See pulse_pattern_night.dart for what the
// numbers are and are not.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../../ui2/ui2.dart';
import 'pulse_pattern_night.dart';

const String kPulseResearchTitle =
    'Repeating nighttime pulse patterns (research)';

const String kPulseResearchDisclaimer =
    'Research view. Not a breathing measurement, not a screening and not a '
    'diagnosis. The band has no airflow or oxygen sensor.';

const String kPulseResearchZeroLine =
    'Zero patterns means zero under this detector on the analysed data. It '
    'does not mean breathing was normal.';

/// The research screen: the two permanent lines, one row per night
/// (analysed hours, coverage, count; "not analysed" or the exclusions in
/// words instead of a count), and the evidence links.
class PulsePatternResearchScreen extends StatelessWidget {
  const PulsePatternResearchScreen({
    super.key,
    required this.nights,
    this.open = open3rdPartyLink,
  });

  final List<PulsePatternNight> nights;

  /// Opens an evidence link; defaults to [open3rdPartyLink].
  final Future<bool> Function(String url) open;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(kPulseResearchTitle),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                // Permanent: no close, no dismiss, nothing that remembers.
                Surface(
                  child: Text(kPulseResearchDisclaimer,
                      style: F.body.copyWith(color: p.ink)),
                ),
                const SizedBox(height: S.x3),
                Surface(
                  child: Text(kPulseResearchZeroLine,
                      style: F.body.copyWith(color: p.ink)),
                ),
                const SizedBox(height: S.x3),
                if (nights.isEmpty)
                  Surface(
                    child: Text('No nights to show yet.',
                        style: F.body.copyWith(color: p.ink2)),
                  ),
                for (final n in nights) ...[
                  _NightRow(night: n),
                  const SizedBox(height: S.x3),
                ],
                Section(
                  'Evidence',
                  Surface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Link(
                            label: 'Hayano 2011',
                            text: 'Hayano 2011 · '
                                'doi.org/10.1161/CIRCEP.110.958009',
                            url: 'https://doi.org/10.1161/CIRCEP.110.958009',
                            open: open),
                        _Link(
                            label: 'Berry 2012',
                            text: 'Berry 2012 · doi.org/10.5664/jcsm.2172',
                            url: 'https://doi.org/10.5664/jcsm.2172',
                            open: open),
                      ],
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

/// One night, in words. The detector's own note is deliberately not drawn:
/// it uses vocabulary this view must not repeat.
class _NightRow extends StatelessWidget {
  const _NightRow({required this.night});
  final PulsePatternNight night;

  static String _hours(double h) => '${h.toStringAsFixed(1)} h analysed';
  static String _percent(double c) => '${(c * 100).round()}% coverage';

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final n = night;
    final hours = n.analysedHours;
    final coverage = n.coverage;
    final count = n.cycleCount;
    // Not analysed: no hours, no coverage, no count, only the words.
    // Excluded: what was measured, then why it is out, and no count.
    final detail = <String>[
      if (count != null && hours != null) _hours(hours),
      if (count != null && coverage != null) _percent(coverage),
      ...n.exclusions,
    ].join(' · ');
    return Surface(
      key: ValueKey('pulse-night:${n.dayId}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(n.dayId,
            style: F.body.copyWith(
                color: p.ink, fontWeight: FontWeight.w600)),
        if (n.admitted) ...[
          const SizedBox(height: S.x1),
          Text(count == 1 ? '1 pattern' : '$count patterns',
              style: F.head.copyWith(color: p.ink)),
        ],
        if (detail.isNotEmpty) ...[
          const SizedBox(height: S.x1),
          Text(detail, style: F.cap.copyWith(color: p.ink2)),
        ],
      ]),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({
    required this.label,
    required this.text,
    required this.url,
    required this.open,
  });
  final String label, text, url;
  final Future<bool> Function(String url) open;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      link: true,
      semanticLabel: label,
      onTap: () => open(url),
      child: ExcludeSemantics(
        child: Text(text,
            style: F.cap.copyWith(
              color: p.on(C.blue),
              decoration: TextDecoration.underline,
            )),
      ),
    );
  }
}

/// The way in: built only when `Feature.developerMode` is available AND
/// `Prefs.explorePulsePatterns` is on; otherwise an empty box. Tapping it
/// opens [PulsePatternResearchScreen] over [nights].
class PulsePatternResearchEntry extends StatelessWidget {
  const PulsePatternResearchEntry({super.key, required this.nights});

  final List<PulsePatternNight> nights;

  @override
  Widget build(BuildContext c) {
    if (!c.caps.has(Feature.developerMode) ||
        !Prefs.getBool(Prefs.explorePulsePatterns, false)) {
      return const SizedBox.shrink();
    }
    final p = P.of(c);
    return Surface(
      onTap: () => Navigator.of(c).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'PulsePatternResearchScreen'),
        builder: (_) => PulsePatternResearchScreen(nights: nights),
      )),
      child: Row(children: [
        Expanded(
          child: Text(kPulseResearchTitle,
              style: F.body.copyWith(
                  color: p.ink, fontWeight: FontWeight.w600)),
        ),
        Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
      ]),
    );
  }
}
