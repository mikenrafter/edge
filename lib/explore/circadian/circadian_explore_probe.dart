// circadian_explore_probe.dart — the Device lab Probes tab's door to the
// circadian explore surface.
//
// Nothing is read until both gates are open (developer mode AND
// Prefs.exploreCircadian); shut, this draws nothing and touches no data. Open,
// it reads once (sleep windows, stored heart rate curves; the fit runs off the
// UI isolate) and then shows [CircadianExploreEntry]. A failed read says so
// and offers a retry: it is never drawn as an empty result.

import 'package:flutter/material.dart';

import '../../data/local_repository.dart';
import '../../ui2/ui2.dart';
import 'circadian_explore_data.dart';
import 'circadian_explore_screen.dart';

typedef CircadianLoader = Future<CircadianExploreData> Function(
    LocalRepository repo);

class CircadianExploreProbe extends StatefulWidget {
  const CircadianExploreProbe({super.key, required this.repo, this.load});

  /// Null when the database layer is not up: nothing to read, nothing drawn.
  final LocalRepository? repo;

  /// Test seam; defaults to [loadCircadianExploreData].
  final CircadianLoader? load;

  @override
  State<CircadianExploreProbe> createState() => _CircadianExploreProbeState();
}

class _CircadianExploreProbeState extends State<CircadianExploreProbe> {
  Future<CircadianExploreData>? _data;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    if (repo == null || !CircadianExploreEntry.shown(context)) {
      return const SizedBox.shrink();
    }
    final future =
        _data ??= (widget.load ?? loadCircadianExploreData)(repo);
    final p = P.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: FutureBuilder<CircadianExploreData>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Surface(
            key: const ValueKey('circadian-explore-error'),
            onTap: () => setState(() => _data = null),
            child: Text(
              'Could not read the data for the circadian estimate. '
              'Tap to try again.',
              style: F.body.copyWith(color: p.ink),
            ),
          );
        }
        final d = snap.data;
        if (d == null) {
          return Surface(
            key: const ValueKey('circadian-explore-loading'),
            child: Text('Reading your recorded rhythm…',
                style: F.cap.copyWith(color: p.ink2)),
          );
        }
        return CircadianExploreEntry(summary: d.summary, rhythm: d.rhythm);
      },
    ));
  }
}
