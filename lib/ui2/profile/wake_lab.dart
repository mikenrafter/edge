// wake_lab.dart — on the Alarms screen: the sleep settings that live elsewhere
// (reused rows / links, no logic of their own), and, in developer mode only,
// the Wake lab (wake dev harness: rule picker and bounded coefficients). Wake
// lab edits go straight to prefs (AppState.setWakeHarness), never through the
// alarm schedule Save. Developer copy is literal, like Device lab. Part of
// alarm.dart: these sections belong to that screen only.
part of 'alarm.dart';

/// Sleep settings reachable from the Alarms screen. The expected sleep
/// schedule already has its own row on this screen.
class _AlarmSleepSettings extends StatefulWidget {
  const _AlarmSleepSettings();
  @override
  State<_AlarmSleepSettings> createState() => _AlarmSleepSettingsState();
}

class _AlarmSleepSettingsState extends State<_AlarmSleepSettings> {
  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return SettingsAccordion(
      'Sleep settings',
      id: 'alarm_sleep',
      initiallyExpanded: false,
      children: [
        SwitchRow(
          l?.experimentalSleepHmm ?? 'Experimental sleep staging (HMM)',
          Prefs.experimentalSleepHmm,
          (on) => setState(() => Prefs.setExperimentalSleepHmm(on)),
          sub: l?.experimentalSleepHmmDescription ??
              'Research method for future calculations. Not medical advice. '
                  'Saved finalized nights stay unchanged; reanalyse a night to '
                  'apply it.',
        ),
        SwitchRow(
          l?.sleepWakeZoom ?? 'Zoom wake-up events',
          Prefs.sleepWakeZoomOn,
          (on) => setState(() => Prefs.setSleepWakeZoom(on)),
          sub: l?.sleepWakeZoomDescription ??
              'Zoom the end of the sleep chart when wake-up events are crowded',
        ),
        SetRow(
          LucideIcons.moon,
          C.blue,
          l?.activityNapAlerts ?? 'Detected naps',
          sub: l?.activityPushHint ??
              'Push alerts only. Suggestions remain in Detected activities.',
          onTap: () => goto(c, const NotificationSettings()),
        ),
      ],
    );
  }
}

/// The steppable coefficients.
enum _Coef { triggerRun, minConfidence, evidenceAge, hrRise, motion, veto }

WakeHarnessConfig _withCoef(WakeHarnessConfig h, _Coef k, double v) {
  double r2(double x) => (x * 100).roundToDouble() / 100;
  return switch (k) {
    _Coef.triggerRun => h.copyWith(triggerRunSec: v.round()),
    _Coef.minConfidence => h.copyWith(minConfidence: r2(v)),
    _Coef.evidenceAge => h.copyWith(evidenceAgeCapSec: v.round()),
    _Coef.hrRise => h.copyWith(hrRiseBpm: v.roundToDouble()),
    _Coef.motion => h.copyWith(motionCeilingG: r2(v)),
    _Coef.veto => h.copyWith(vetoMinConfidence: r2(v)),
  };
}

/// Developer mode only (the caller decides). Shows each value with its
/// default and bounds, and what the effective value is made of.
class _WakeLabSection extends StatelessWidget {
  const _WakeLabSection(this.app);
  final AppState app;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final h = app.wakeHarness;
    void set(WakeHarnessConfig next) => app.setWakeHarness(next);
    Widget note(String s) => Padding(
      padding: const EdgeInsets.only(bottom: S.x2),
      child: Text(s, style: F.cap.copyWith(color: p.ink2)),
    );
    Widget stepper(
      String label,
      double value,
      HarnessBound b,
      _Coef k, {
      String unit = '',
      int digits = 0,
      String? effective,
    }) {
      String f(double v) => '${v.toStringAsFixed(digits)}$unit';
      final down = value - b.step >= b.min - 1e-9;
      final up = value + b.step <= b.max + 1e-9;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x1),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$label: ${f(value)}',
                      style: F.body.copyWith(color: p.ink)),
                  Text(
                    'default ${f(b.defaultValue)}, ${f(b.min)}–${f(b.max)}'
                    '${effective == null ? '' : '. Effective: $effective'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(LucideIcons.minus),
              onPressed: down
                  ? () => app.setWakeHarness(_withCoef(h, k, value - b.step))
                  : null,
            ),
            IconButton(
              icon: const Icon(LucideIcons.plus),
              onPressed: up
                  ? () => app.setWakeHarness(_withCoef(h, k, value + b.step))
                  : null,
            ),
          ],
        ),
      );
    }

    return SettingsAccordion(
      'Wake lab',
      id: 'alarm_wake_lab',
      initiallyExpanded: false,
      children: [
        note('Developer only. Changes the early buzz inside the window; the '
            'band alarm at the wake time is never affected. Each wake records '
            'the rule and effective values it ran under.'),
        SegmentedButton<WakeRule>(
          segments: const [
            ButtonSegment(value: WakeRule.natural, label: Text('Natural')),
            ButtonSegment(value: WakeRule.legacy, label: Text('Legacy')),
            ButtonSegment(value: WakeRule.hybrid, label: Text('Hybrid')),
          ],
          selected: {h.rule},
          onSelectionChanged: (s) => set(h.copyWith(rule: s.first)),
        ),
        const SizedBox(height: S.x2),
        if (h.rule == WakeRule.natural) ...[
          stepper('Trigger run', h.triggerRunSec.toDouble(),
              WakeHarnessConfig.triggerRunBound, _Coef.triggerRun,
              unit: ' s',
              effective: 'this plus the learned offset (±60 s), at least 30 s'),
          stepper('Min confidence', h.minConfidence,
              WakeHarnessConfig.minConfidenceBound, _Coef.minConfidence,
              digits: 2),
          SwitchRow('REM only (not awake)', h.remOnly,
              (on) => set(h.copyWith(remOnly: on))),
        ],
        if (h.rule != WakeRule.legacy)
          stepper('Evidence age cap', h.evidenceAgeCapSec.toDouble(),
              WakeHarnessConfig.evidenceAgeBound, _Coef.evidenceAge,
              unit: ' s',
              effective: 'planner cap; the stager itself abstains after 120 s'),
        if (h.rule != WakeRule.natural) ...[
          stepper('HR rise', h.hrRiseBpm, WakeHarnessConfig.hrRiseBound,
              _Coef.hrRise,
              unit: ' bpm',
              effective: 'the higher of this and the journal adjustment'),
          stepper('Motion ceiling', h.motionCeilingG,
              WakeHarnessConfig.motionCeilingBound, _Coef.motion,
              unit: ' g',
              digits: 2,
              effective: 'the lower of this and the journal adjustment'),
        ],
        if (h.rule == WakeRule.hybrid) ...[
          stepper('NREM veto confidence', h.vetoMinConfidence,
              WakeHarnessConfig.vetoBound, _Coef.veto,
              digits: 2),
          SwitchRow('Require REM or awake', h.requireRemOrWake,
              (on) => set(h.copyWith(requireRemOrWake: on)),
              sub: 'On: no current stage holds the buzz.'),
          note('Hybrid needs Natural Wake on for the day; while the old Smart '
              'Wake runs, plain legacy runs instead.'),
        ],
        note('Offline sleep analysis (cardio / HMM) is under Sleep settings; '
            'live wake staging is unchanged by it.'),
        TextButton(
          onPressed: h.isDefault ? null : () => set(WakeHarnessConfig.defaults),
          child: const Text('Reset to defaults'),
        ),
      ],
    );
  }
}
