import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';

class WakeCard extends StatefulWidget {
  const WakeCard({super.key});
  @override
  State<WakeCard> createState() => _WakeCardState();
}

class _WakeCardState extends State<WakeCard> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState?>();
    final epoch = app?.activeWakeEpoch;
    if (app == null || epoch == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    return Padding(padding: const EdgeInsets.only(bottom: S.x3),
      child: Surface(key: const ValueKey('wake-card'), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(app.naturalWakeBuzzing
              ? (l?.wakeNaturalBuzzing ?? 'Natural wake is buzzing')
              : (l?.wakeGradualBuzzing ?? 'Gradual wake is buzzing'),
              style: F.t2.copyWith(color: p.ink)),
          const SizedBox(height: S.x1),
          Text(l?.alarmGradualBandUnchanged ??
                  'Your band alarm at the wake time is unchanged.',
              style: F.cap.copyWith(color: p.ink2)),
          const SizedBox(height: S.x3),
          BigButton(
            l?.wakeImUp ?? "I'm up",
            icon: LucideIcons.sunrise,
            onTap: () async {
              try {
                await app.acknowledgeWake(epoch);
              } catch (e) {
                if (c.mounted) {
                  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e')));
                }
              }
            },
          ),
        ],
      )),
    );
  }
}
