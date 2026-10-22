import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../grammar.dart';
import '../theme.dart';

class ConsentPromptHost extends StatefulWidget {
  const ConsentPromptHost({super.key, required this.child});
  final Widget child;

  @override
  State<ConsentPromptHost> createState() => _ConsentPromptHostState();
}

class _ConsentPromptHostState extends State<ConsentPromptHost> {
  bool telemetry = false;
  bool health = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.consentPromptDue) return Stack(children: [widget.child]);
    final l = AppLocalizations.of(context);
    final p = P.of(context);
    final showHealth = context.caps.has(Feature.healthShare);
    return Stack(children: [
      widget.child,
      Positioned.fill(
        child: ColoredBox(
          color: p.bg.withValues(alpha: .92),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(S.x6),
                child: Material(child: Surface(
                  pad: const EdgeInsets.all(S.x6),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(l?.consentPromptTitle ?? 'Your privacy choices', key: const ValueKey('consent-prompt'), style: F.head.copyWith(color: p.ink)),
                    const SizedBox(height: S.x3),
                    Text(l?.consentPromptBody ?? 'Choose whether to share anonymous diagnostics or contribute health data. Both are off unless you choose otherwise.'),
                    ListTile(
                      title: Text(l?.settingsCrashReportsRowTitle ?? 'Crash reports'),
                      subtitle: Text(l?.settingsCrashReportsRowSub ?? 'Nothing is sent until you say so'),
                      trailing: Switch(key: const ValueKey('consent-telemetry'), value: telemetry,
                        onChanged: (v) => setState(() => telemetry = v)),
                    ),
                    if (showHealth) ListTile(
                      title: Text(l?.settingsContributeHealthDataRowTitle ?? 'Contribute my health data'),
                      subtitle: Text(l?.settingsContributeHealthDataRowSub ?? 'Uploads your whole database once a day, on Wi-Fi and charging, to improve the algorithms'),
                      trailing: Switch(key: const ValueKey('consent-health-share'), value: health,
                        onChanged: (v) => setState(() => health = v)),
                    ),
                    const SizedBox(height: S.x3),
                    Row(children: [
                      Expanded(child: OutlinedButton(key: const ValueKey('consent-decline'), onPressed: () async {
                        await app.setTelemetryConsent(false);
                        if (showHealth) await app.setHealthShareConsent(false);
                      }, child: Text(l?.consentDecline ?? 'No thanks'))),
                      const SizedBox(width: S.x2),
                      Expanded(child: FilledButton(key: const ValueKey('consent-confirm'), onPressed: () async {
                        await app.setTelemetryConsent(telemetry);
                        if (showHealth) await app.setHealthShareConsent(health);
                      }, child: Text(l?.consentConfirm ?? 'Continue'))),
                    ]),
                  ]),
                )),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
