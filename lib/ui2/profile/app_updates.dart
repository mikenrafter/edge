// App updates: the Settings row and the two source cards. Opens GitHub release
// pages only; there is no download, install or mode-switch control.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../sync/update_coordinator.dart';

/// The one line Settings shows for [snapshot].
String updateSummary(AppLocalizations l, UpdateSnapshot snapshot) => '';

class AppUpdatesRow extends StatelessWidget {
  const AppUpdatesRow({super.key, required this.snapshot, this.onTap});
  final UpdateSnapshot snapshot;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class AppUpdatesScreen extends StatefulWidget {
  const AppUpdatesScreen({super.key, required this.service});
  final UpdateCoordinator service;
  @override
  State<AppUpdatesScreen> createState() => _AppUpdatesScreenState();
}

class _AppUpdatesScreenState extends State<AppUpdatesScreen> {
  @override
  Widget build(BuildContext context) => const Scaffold();
}
