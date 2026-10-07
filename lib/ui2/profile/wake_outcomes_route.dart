// wake_outcomes_route.dart — Settings > Developer > Wake outcomes. The route
// around WakeOutcomesScreen (lib/wake/outcomes/): it loads the stored log,
// asks the shadow policy what it WOULD choose against the user's current
// Natural window, and stores a grogginess rating. Developer-only; nothing here
// changes an alarm.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../wake/outcomes/wake_outcome.dart';
import '../../wake/outcomes/wake_outcomes_screen.dart';
import '../../wake/outcomes/wake_preference_policy.dart';
import '../ui2.dart';

class WakeOutcomesRoute extends StatefulWidget {
  const WakeOutcomesRoute({super.key});

  @override
  State<WakeOutcomesRoute> createState() => _WakeOutcomesRouteState();
}

class _WakeOutcomesRouteState extends State<WakeOutcomesRoute> {
  List<WakeOutcome>? _outcomes;
  int _windowMinutes = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final window = app.currentNaturalWindowMinutes;
    final outcomes = await app.loadWakeOutcomes();
    if (!mounted) return;
    setState(() {
      _outcomes = outcomes;
      _windowMinutes = window;
    });
  }

  Future<void> _rate(int wakeSec, int grogginess) async {
    await context.read<AppState>().rateWakeOutcome(wakeSec, grogginess);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final outcomes = _outcomes;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Wake outcomes'),
          ),
          Expanded(
            child: outcomes == null
                ? const SizedBox.shrink()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
                    children: [
                      WakeOutcomesScreen(
                        outcomes: outcomes,
                        shadow: evaluate(outcomes,
                            currentWindowMinutes: _windowMinutes),
                        onRate: _rate,
                      ),
                    ],
                  ),
          ),
        ]),
      ),
    );
  }
}
