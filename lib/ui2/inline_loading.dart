// The loading state of ONE part of a page: a card with a small spinner in it,
// standing where the content that is still being read will go. The rest of the
// page (title, header, whatever was cheap to read) is already drawn around it.
//
// A page-wide spinner in place of the whole body is what this replaces. It hid
// everything, including what had already arrived, until the slowest read ended.
import 'package:flutter/material.dart';

import 'grammar.dart';
import 'theme.dart';

class InlineLoading extends StatelessWidget {
  const InlineLoading({super.key});

  @override
  Widget build(BuildContext context) => const Surface(
        pad: EdgeInsets.symmetric(vertical: S.x6),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
}
