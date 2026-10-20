// The loading state of ONE part of a page: a card with a small spinner in it,
// standing where the content that is still being read will go. The rest of the
// page (title, header, whatever was cheap to read) is already drawn around it.
//
// A page-wide spinner in place of the whole body is what this replaces. It hid
// everything, including what had already arrived, until the slowest read ended.
//
// Every spinner says what is happening now ([status]), optionally with a
// second live line ([detail], e.g. the calculation's day count). [height]
// reserves the loaded content's height, so the content landing fills the
// space instead of pushing the page down.
import 'package:flutter/material.dart';

import 'grammar.dart';
import 'theme.dart';

class InlineLoading extends StatelessWidget {
  /// What is happening now: "Reading last night". Not reassurance.
  final String status;

  /// A second status line, e.g. 'Calculating · day 3 of 12'.
  final String? detail;

  /// The final content's height, reserved while loading. Null: natural size.
  final double? height;

  const InlineLoading({
    super.key,
    required this.status,
    this.detail,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final d = detail;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: S.x2),
        Text(status,
            textAlign: TextAlign.center, style: F.cap.copyWith(color: p.ink2)),
        if (d != null && d.isNotEmpty)
          Text(d,
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
