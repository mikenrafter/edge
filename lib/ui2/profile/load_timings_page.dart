import 'package:flutter/material.dart';
import '../../data/load_timings.dart';

class LoadTimingsPage extends StatelessWidget {
  const LoadTimingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final samples = LoadTimings.shared.samples.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Screen load timings')),
      body: ListView(
        children: [
          const ListTile(
            subtitle: Text(
              'Last 128 reads and calculation spans. Query time includes native queueing. Parallel reads overlap.',
            ),
          ),
          if (samples.isEmpty)
            const ListTile(title: Text('Open Review to record a load.')),
          for (final s in samples)
            ListTile(
              title: Text('${s.name} · ${s.phase}'),
              subtitle: Text(s.route),
              trailing: Text('${(s.micros / 1000).toStringAsFixed(1)} ms'),
            ),
        ],
      ),
    );
  }
}
