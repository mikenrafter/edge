import 'package:flutter/material.dart';
import '../ui2.dart';
import '../guides/help_entry.dart';
import 'sleep_detail.dart';

// The Sleep tab.
//
// Sleep used to be spread over the Home ring, a Health row that opened a
// generic chart, Wellness's "Recovery" sub-tab (need, debt, bedtime), Health's
// Body clock and the alarm in Settings. This tab is the Sleep screen itself,
// with those pieces under the night. The screens are the same ones; only
// where they live changed.


class SleepTab extends StatelessWidget {
  const SleepTab({super.key});
  @override
  Widget build(BuildContext c) {
    final request = ShellDate.maybeOf(c);
    return SleepDetail(key: ValueKey(request?.revision ?? 0),
      day: request?.date, embedded: true,
      footer: const [HelpEntry(topic: GuideTopic.sleep)]);
  }
}

