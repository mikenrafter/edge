import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';

/// Home and the primary band detail render the same operation state.
class SyncControl extends StatelessWidget {
  final SyncPresentationState state;
  final VoidCallback? onSync;
  const SyncControl({super.key, required this.state, this.onSync});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        onPressed: state.busy ? null : onSync,
        icon: state.busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.sync),
        label: const Text('Sync now'),
      ),
      Text(state.description),
      if (state.lastSuccess case final time?)
        Text(
          'Last successful sync: ${TimeOfDay.fromDateTime(time.toLocal()).format(context)}',
        ),
    ],
  );
}

class HomeSyncControl extends StatelessWidget {
  const HomeSyncControl({super.key});
  @override
  Widget build(BuildContext context) {
    AppState? app;
    try {
      app = context.watch<AppState>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    final SyncPresentationState state = app.syncPresentation;
    return SyncControl(state: state, onSync: app.syncNow);
  }
}
