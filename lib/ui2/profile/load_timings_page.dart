import 'package:flutter/material.dart';
import '../../data/load_timings.dart';

class LoadTimingsPage extends StatefulWidget {
  const LoadTimingsPage({super.key});
  @override
  State<LoadTimingsPage> createState() => _LoadTimingsPageState();
}

class _LoadTimingsPageState extends State<LoadTimingsPage> {
  @override
  Widget build(BuildContext context) {
    final samples = LoadTimings.shared.samples.reversed.toList();
    final on = LoadTimings.shared.enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('Screen load timings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Record load timings'),
            subtitle: const Text(
              'Off by default. Kept on this phone only, never in a backup.',
            ),
            value: on,
            onChanged: (v) => setState(() => LoadTimings.shared.setEnabled(v)),
          ),
          const ListTile(
            subtitle: Text(
              'Last 128 screen reads and calculation spans, and the last 32 from the background. Query time includes native queueing. Parallel reads overlap.',
            ),
          ),
          if (samples.isEmpty)
            ListTile(
              title: Text(on
                  ? 'Open Review to record a load.'
                  : 'Turn recording on, then open Review.'),
            ),
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
