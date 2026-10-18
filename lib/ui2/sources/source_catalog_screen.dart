// The Sources area: the Source Catalog first, then the resolved-data detail
// and the priority editor it leads to. Scaffold routes over the read seam
// (`AppState.sourceService`); the drawing lives in the pure views.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/adapters/signals.dart' show InputSignal;
import '../../data/coverage_resolver.dart' show kExclusiveOwnershipSignals;
import '../../data/db.dart' show LocalDb;
import '../../sources/resolved_window.dart';
import '../../sources/source_catalog.dart' show SourceCard;
import '../../state/app_state.dart';
import '../grammar.dart';
import '../profile/devices.dart' show SignalPriorityScreen, signalDisplayName;
import '../profile/profile.dart' show SetRow, goto;
import '../theme.dart';
import 'resolved_data_view.dart' show ResolvedWindowPicker;
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
                  sub: 'Who won each stretch of your recorded data, and why',
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
  int? days,
  List<InputSignal> signals,
  Map<String, String> names,
  Map<InputSignal, List<Map<String, Object?>>> rows,
});

/// Resolved data over the window the user chose, one signal at a time.
class ResolvedDataScreen extends StatefulWidget {
  const ResolvedDataScreen({super.key});

  @override
  State<ResolvedDataScreen> createState() => _ResolvedDataScreenState();
}

class _ResolvedDataScreenState extends State<ResolvedDataScreen> {
  int _tab = 0;
  // Null until the stored choice is read, then the choice itself (null inside
  // means no cutoff), so the first load never uses the wrong window.
  ({int? days})? _window;

  Future<_Resolved> _load(BuildContext c) async {
    final service = c.read<AppState>().sourceService;
    final days = _window == null ? await loadResolvedWindowDays() : _window!.days;
    _window = (days: days);
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
    int? earliest;
    if (days == null) {
      for (final d in (await LocalDb.coverageExtentByDevice()).values) {
        for (final e in d.values) {
          if (earliest == null || e.start < earliest) earliest = e.start;
        }
      }
    }
    final from = resolvedWindowStart(now, days, earliest: earliest);
    final to = now.millisecondsSinceEpoch ~/ 1000;
    return (
      days: days,
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
        build: (c, data, reload) {
          if (data.signals.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(S.x4),
              child: NoData(message: 'No source declares a signal yet'),
            );
          }
          final tab = _tab.clamp(0, data.signals.length - 1);
          final sig = data.signals[tab];
          final shown = capResolvedRows(data.rows[sig]!);
          return ListView(
            padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
            children: [
              ResolvedWindowPicker(
                days: data.days,
                onChanged: (v) async {
                  await saveResolvedWindowDays(v);
                  _window = (days: v);
                  await reload();
                },
              ),
              const SizedBox(height: S.x2),
              SubTabs(
                [for (final s in data.signals) signalDisplayName(c, s)],
                tab,
                (i) => setState(() => _tab = i),
              ),
              if (shown.rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: S.x4),
                  child: NoData(
                      message: 'Nothing was recorded for this signal in '
                          '${resolvedWindowLabel(data.days)}'),
                )
              else ...[
                if (shown.total > shown.rows.length)
                  Padding(
                    padding: const EdgeInsets.only(top: S.x3),
                    child: Text(
                      'Showing the most recent ${shown.rows.length} of '
                      '${shown.total} stretches. Choose a shorter window to '
                      'see the rest.',
                      style: F.cap.copyWith(color: P.of(c).ink3),
                    ),
                  ),
                const SourceViews()
                    .resolvedData(rows: shown.rows, names: data.names),
              ],
            ],
          );
        },
      );
}
