// Owner: SleepCoordinator retains receipt failures; this app-level view only
// presents and acknowledges them. Route disposal never controls delivery.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';

class SleepOperationErrors extends StatelessWidget {
  const SleepOperationErrors({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final owner = context.watch<AppState>().sleepOperations;
    final failures = owner.failures;
    return Stack(
      children: [
        child,
        if (failures.isNotEmpty)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final failure in failures)
                        ListTile(
                          title: Text(
                            'Couldn’t save your change for ${failure.day}: ${failure.message}',
                          ),
                          trailing: TextButton(
                            onPressed: () =>
                                owner.acknowledge(failure.operation),
                            child: const Text('Dismiss'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
