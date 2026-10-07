// moment_follow_up.dart — the Home card and the screen behind its "Answer".

import 'package:flutter/material.dart';

import '../../gestures/moment_follow_ups.dart';

/// "You marked N moments — what were they?" with an Answer button.
class MomentFollowUpCard extends StatelessWidget {
  const MomentFollowUpCard({super.key, required this.count, this.onAnswer});
  final int count;
  final VoidCallback? onAnswer;

  @override
  Widget build(BuildContext c) =>
      throw UnimplementedError('MomentFollowUpCard.build');
}

/// The card, or null when the setting is off or nothing is pending. Pure.
Widget? momentFollowUpCardFor({
  required bool enabled,
  required int count,
  VoidCallback? onAnswer,
}) =>
    throw UnimplementedError('momentFollowUpCardFor');

/// Home's helper: null with no AppState above (a golden), like
/// `_naturalWakeCard`.
Widget? momentFollowUpCard(BuildContext c) =>
    throw UnimplementedError('momentFollowUpCard');

/// Each pending moment with its quick choices and Skip.
class MomentFollowUpScreen extends StatefulWidget {
  const MomentFollowUpScreen({
    super.key,
    this.preloaded,
    this.writer = const MomentAnswerWriter(),
    this.now,
  });

  /// Injected in tests; null reads them from the database.
  final List<PendingMoment>? preloaded;
  final MomentAnswerWriter writer;
  final DateTime? now;

  @override
  State<MomentFollowUpScreen> createState() => _MomentFollowUpScreenState();
}

class _MomentFollowUpScreenState extends State<MomentFollowUpScreen> {
  @override
  Widget build(BuildContext c) =>
      throw UnimplementedError('MomentFollowUpScreen.build');
}
