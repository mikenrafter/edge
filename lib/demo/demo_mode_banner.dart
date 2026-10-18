// demo_mode_banner.dart — the persistent "this is not real data" strip.
//
// Rendered by `_Gate` (app.dart) ABOVE every screen while demo mode is on —
// onboarding, profile setup, and the shell alike — so there is no path through
// the app where it is possible to forget which mode it is in. See
// `demo_data_generator.dart`'s header for what demo mode actually writes.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/prefs.dart';
import '../ui2/onboarding/pairing.dart' show OnboardingBypass;
import '../ui2/ui2.dart';
import 'demo_data_generator.dart';

class DemoModeBanner extends StatefulWidget {
  const DemoModeBanner({super.key});

  @override
  State<DemoModeBanner> createState() => _DemoModeBannerState();
}

class _DemoModeBannerState extends State<DemoModeBanner> {
  bool _exiting = false;

  Future<void> _exit() async {
    if (_exiting) return;
    // Captured before any `await` — never re-read `context` after one.
    final app = context.read<AppState>();
    setState(() => _exiting = true);
    // Best-effort: even if the purge throws partway through, clearing the
    // flag first means the banner and the gate agree demo mode is off rather
    // than leaving a orphaned "demo" strip the user can never dismiss.
    Prefs.setBool(Prefs.demoModeEnabled, false);
    try {
      await DemoDataGenerator.purge(app: app);
    } finally {
      // `_Gate` doesn't watch this pref directly — it rebuilds off
      // `OnboardingBypass.revision`, the same signal a skip/profile-seen
      // bypass already uses to force a re-evaluation.
      OnboardingBypass.revision.value++;
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: p.wash(C.orange),
          border: Border(top: BorderSide(color: p.line)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
          child: Row(children: [
            Icon(LucideIcons.sparkles, size: 18, color: p.on(C.orange)),
            const SizedBox(width: S.x3),
            Expanded(
              child: Text(
                'Demo mode. All data on screen is generated sample data.',
                style: F.cap.copyWith(
                  color: p.on(C.orange),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: S.x3),
            _exiting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.on(C.orange),
                    ),
                  )
                : Pressable(
                    onTap: _exit,
                    semanticLabel: 'Exit demo mode',
                    child: Text(
                      'Exit',
                      style: F.cap.copyWith(
                        color: p.on(C.orange),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ]),
        ),
      ),
    );
  }
}
