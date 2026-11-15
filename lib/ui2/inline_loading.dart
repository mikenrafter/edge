// A pending section keeps its status visible and delays placeholder paint.
import 'package:flutter/material.dart';

import 'grammar.dart';
import 'skeleton/async_section.dart';
import 'theme.dart';

class InlineLoading extends StatelessWidget {
  /// What is happening now: "Reading last night". Not reassurance.
  final String status;

  /// A second status line, e.g. 'Calculating · day 3 of 12'.
  final String? detail;

  /// The final content's height, reserved while loading. Null: natural size.
  final double? height;

  /// Keep the detail line's height when [detail] is null, so the line
  /// appearing later pushes nothing.
  final bool reserveDetail;

  /// One row, no card: a small spinner and the status, for a line inside a card
  /// that already exists (the Home rings' help strip), where a card in a card
  /// would be taller than the line it stands in for.
  final bool compact;

  const InlineLoading({
    super.key,
    required this.status,
    this.detail,
    this.height,
    this.reserveDetail = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final d = detail;
    if (compact) {
      return Row(children: [
        const SizedBox(
          width: 15,
          height: 15,
          child: PendingMark(),
        ),
        const SizedBox(width: S.x2),
        Expanded(
          child: Text(
            [status, if (d != null && d.isNotEmpty) d].join(' · '),
            style: F.cap.copyWith(color: p.ink2),
          ),
        ),
      ]);
    }
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const PendingContent(pending: true, child: PendingRows(count: 2, rowHeight: 30)),
        const SizedBox(height: S.x2),
        Text(status,
            textAlign: TextAlign.center, style: F.cap.copyWith(color: p.ink2)),
        if (d != null && d.isNotEmpty)
          Text(d,
              textAlign: TextAlign.center,
              style: F.cap.copyWith(color: p.ink3))
        else if (reserveDetail)
          Text('',
              textAlign: TextAlign.center,
              style: F.cap.copyWith(color: p.ink3)),
      ],
    );
    final h = height;
    return SizedBox(
      height: h,
      child: Surface(
        pad: const EdgeInsets.symmetric(vertical: S.x6, horizontal: S.x4),
        child: h == null
            ? Center(child: body)
            : SizedBox.expand(child: Center(child: body)),
      ),
    );
  }
}
