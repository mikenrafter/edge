import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import '../ui2/profile/home_header_settings.dart';
import '../ui2/profile/profile.dart' show SettingsAccordion, SetRow;
import '../ui2/theme.dart';
import 'pilot_flags.dart';

class LabsSection extends StatefulWidget {
  const LabsSection({
    super.key,
    required this.hmm,
    required this.onHmm,
    this.onAlarmSourceChanged,
    this.alarmNotices,
  });

  final bool hmm;
  final VoidCallback? onHmm;
  final Future<void> Function()? onAlarmSourceChanged;
  final Widget? alarmNotices;

  @override
  State<LabsSection> createState() => _LabsState();
}

class _LabsState extends State<LabsSection> {
  String? _error;
  bool _saving = false;

  static const _flags = [
    PilotFlag.homeHeader,
    PilotFlag.alarmScreen,
    PilotFlag.wakeMethods,
    PilotFlag.timelines,
    PilotFlag.sleepSummary,
    PilotFlag.syncStrip,
    PilotFlag.observations,
    PilotFlag.fullWidthTabs,
  ];

  Future<void> _set(PilotFlag flag, bool enabled) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await PilotFlags.set(flag, enabled);
      if (flag == PilotFlag.alarmScreen || flag == PilotFlag.wakeMethods) {
        await widget.onAlarmSourceChanged?.call();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
    return ListenableBuilder(
      listenable: PilotFlags.revision,
      builder: (context, _) => SettingsAccordion(l.pilotLabs, id: 'settings_labs', children: [
        for (final flag in _flags) ...[
          SwitchListTile(
            key: ValueKey(flag.key),
            secondary: const Icon(LucideIcons.flaskConical),
            title: Text(switch (flag) {
              PilotFlag.sleepSummary => 'Sleep summary',
              PilotFlag.observations => 'Simplified observations',
              PilotFlag.alarmScreen => l.pilotAlarmScreen,
              PilotFlag.wakeMethods => l.pilotWakeMethods,
              PilotFlag.timelines => l.pilotTimelines,
              PilotFlag.syncStrip => 'Home sync strip',
              PilotFlag.homeHeader => 'Home header',
              PilotFlag.fullWidthTabs => l.labsFullWidthTabs,
            }),
            value: flag.enabled,
            onChanged: _saving ? null : (enabled) => _set(flag, enabled),
          ),
          if (flag.enabled && flag == PilotFlag.homeHeader)
            _nested(context, Column(children: [
              const HomeHeaderChoice(),
              SetRow(LucideIcons.circleHelp, C.blue, 'How Compact works',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const HomeHeaderAppearance(),
                ))),
            ])),
          if (flag.enabled && flag == PilotFlag.alarmScreen && widget.alarmNotices != null)
            _nested(context, widget.alarmNotices!),
        ],
        SetRow(LucideIcons.flaskConical, C.indigo, l.experimentalSleepHmm,
          key: const ValueKey('experimental-sleep-hmm'),
          sub: l.experimentalSleepHmmDescription,
          value: widget.hmm ? l.stateOn : l.stateOff,
          onTap: widget.onHmm),
        if (_error != null) Text(_error!),
      ]),
    );
  }

  Widget _nested(BuildContext context, Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(S.x6, 0, S.x3, S.x2),
    child: DecoratedBox(
      decoration: BoxDecoration(color: P.of(context).card2, borderRadius: R.rMd),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: S.x3), child: child),
    ),
  );
}
