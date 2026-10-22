import 'package:flutter/material.dart';

/// Stub for the red tests: the Developer menu's Logs page (share + clear).
class DevLogsPage extends StatelessWidget {
  const DevLogsPage({super.key, this.export, this.clear});
  final Future<bool> Function(Rect origin)? export;
  final Future<void> Function()? clear;

  @override
  Widget build(BuildContext context) => const Scaffold();
}
