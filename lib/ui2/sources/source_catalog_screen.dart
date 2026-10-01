// The Sources area: the Source Catalog first, then the resolved-data detail
// and the priority editor it leads to. Scaffold routes over the read seam
// (`AppState.sourceService`); the drawing lives in the pure views.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/adapters/signals.dart' show InputSignal;
import '../../data/coverage_resolver.dart' show kExclusiveOwnershipSignals;
import '../../sources/source_catalog.dart' show SourceCard;
import '../../state/app_state.dart';
import '../grammar.dart';
import '../profile/devices.dart' show SignalPriorityScreen, signalDisplayName;
import '../profile/profile.dart' show SetRow, goto;
import '../theme.dart';
import 'source_views.dart';

/// Loads once, and shows a failed read as a retryable error rather than an
/// empty list.
class _Loaded<T> extends StatefulWidget {
  final String title;
  final Future<T> Function(BuildContext) load;
  final Widget Function(BuildContext, T, Future<void> Function() reload) build;
  const _Loaded({required this.title, required this.load, required this.build});

  @override
  State<_Loaded<T>> createState() => _LoadedState<T>();
}

class _LoadedState<T> extends State<_Loaded<T>> {
  T? _value;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    try {
      final v = await widget.load(context);
      if (mounted) {
        setState(() {
          _value = v;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(widget.title),
          ),
          Expanded(
            child: _failed
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(S.x4),
                      child: StatusCard(
                        'Could not read your sources',
                        'Nothing was changed. Try again.',
                        fix: 'Try again',
                        icon: LucideIcons.triangleAlert,
                        onFix: () {
                          setState(() => _failed = false);
                          _reload();
                        },
                      ),
                    ),
                  )
                : _value == null
                    ? const Center(child: CircularProgressIndicator())
                    : widget.build(c, _value as T, _reload),
          ),
        ]),
      ),
    );
  }
}

class SourceCatalogScreen extends StatelessWidget {
  const SourceCatalogScreen({super.key});

  @override
  Widget build(BuildContext c) => _Loaded<List<SourceCard>>(
        title: 'Source catalog',
        load: (c) => c.read<AppState>().sourceService.cards(),
        build: (c, cards, _) => ListView(
          padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
          children: [
            const SourceViews().catalog(cards: [for (final x in cards) x.toJson()]),
            Surface(
              pad: const EdgeInsets.symmetric(horizontal: S.x4),
              child: SetRow(LucideIcons.chartGantt, C.teal, 'Resolved data',
                  sub: 'Who won each stretch of the last 3 days, and why',
                  onTap: () => goto(c, const ResolvedDataScreen())),
            ),
            const SizedBox(height: S.x3),
            Surface(
              pad: const EdgeInsets.symmetric(horizontal: S.x4),
              child: SetRow(LucideIcons.arrowUpDown, C.blue, 'Which source wins',
                  sub: 'Set the order for each signal',
                  onTap: () => goto(c, const SignalPriorityScreen())),
            ),
          ],
        ),
      );
}

typedef _Resolved = ({
  List<InputSignal> signals,
  Map<String, String> names,
  Map<InputSignal, List<Map<String, Object?>>> rows,
});

/// Resolved data for the last 3 local days, one signal at a time.
class ResolvedDataScreen extends StatefulWidget {
  const ResolvedDataScreen({super.key});

  @override
  State<ResolvedDataScreen> createState() => _ResolvedDataScreenState();
}

class _ResolvedDataScreenState extends State<ResolvedDataScreen> {
  int _tab = 0;

  Future<_Resolved> _load(BuildContext c) async {
    final service = c.read<AppState>().sourceService;
    final names = {
      for (final x in await service.cards())
        if (x.deviceId != null) x.deviceId!: x.displayLabel,
    };
    final declared = {
      for (final m in await service.prioritySignals()) m['signal'],
    };
    final signals = [
      for (final s in kExclusiveOwnershipSignals)
        if (declared.contains(s.name)) s,
    ];
    final now = DateTime.now();
    // A calendar step back, not 3 * 86400: a day is 23 or 25 h across DST.
    final from = DateTime(now.year, now.month, now.day - 2).millisecondsSinceEpoch ~/ 1000;
    final to = now.millisecondsSinceEpoch ~/ 1000;
    return (
      signals: signals,
      names: names,
      rows: {
        for (final s in signals)
          s: [
            for (final r in await service.resolve(signal: s, from: from, to: to))
              r.toJson(),
          ],
      },
    );
  }

  @override
  Widget build(BuildContext c) => _Loaded<_Resolved>(
        title: 'Resolved data',
        load: _load,
        build: (c, data, _) {
          if (data.signals.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(S.x4),
              child: NoData(message: 'No source declares a signal yet'),
            );
          }
          final tab = _tab.clamp(0, data.signals.length - 1);
          final sig = data.signals[tab];
          return ListView(
            padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
            children: [
              SubTabs(
                [for (final s in data.signals) signalDisplayName(c, s)],
                tab,
                (i) => setState(() => _tab = i),
              ),
              if (data.rows[sig]!.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: S.x4),
                  child: NoData(message: 'Nothing was recorded for this signal in the last 3 days'),
                )
              else
                const SourceViews()
                    .resolvedData(rows: data.rows[sig]!, names: data.names),
            ],
          );
        },
      );
}
