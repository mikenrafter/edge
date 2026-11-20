import 'package:flutter/material.dart';

import '../grammar.dart' show NavBar;
import '../home_header.dart';
import '../theme.dart';

class HomeHeaderAppearance extends StatelessWidget {
  const HomeHeaderAppearance({super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    TextSpan bold(String value) => TextSpan(
      text: value, style: TextStyle(color: p.ink, fontWeight: FontWeight.w600),
    );
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(child: Column(children: [
        const NavBar('How Compact works'),
        Expanded(child: ListView(
          padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x4, S.x6),
          children: [
            const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _HeaderOption(compact: false)),
              SizedBox(width: S.x3),
              Expanded(child: _HeaderOption(compact: true)),
            ]),
            const SizedBox(height: S.x3),
            Text.rich(
              TextSpan(children: [
                bold('‹ ›'), const TextSpan(text: ' change the day\n'),
                bold('Long press'), const TextSpan(text: ' the bar for sync details\n'),
                bold('Colour'), const TextSpan(text: ' behind the date\n'),
                TextSpan(text: 'Green', style: TextStyle(color: p.on(C.green))),
                const TextSpan(text: ' while downloading\n'),
                TextSpan(text: 'Purple', style: TextStyle(color: p.on(C.syncCalculate))),
                const TextSpan(text: ' while calculating'),
              ]),
              style: F.cap.copyWith(height: 1.7, color: p.ink2),
            ),
          ],
        )),
      ])),
    );
  }
}

class HomeHeaderChoice extends StatefulWidget {
  const HomeHeaderChoice({super.key});

  @override
  State<HomeHeaderChoice> createState() => _HomeHeaderChoiceState();
}

class _HomeHeaderChoiceState extends State<HomeHeaderChoice> {
  bool _saving = false;
  bool _failed = false;

  Future<void> _choose(bool compact) async {
    if (_saving || HomeHeader.compact == compact) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    final saved = await HomeHeader.setCompact(compact);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _failed = !saved;
    });
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.start,
          overflowSpacing: S.x1,
          children: [
            Text('Style', style: F.body.copyWith(color: p.ink)),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Standard')),
                ButtonSegment(value: true, label: Text('Compact')),
              ],
              selected: {HomeHeader.compact},
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: p.wash(C.syncCalculate),
                selectedForegroundColor: p.on(C.syncCalculate),
              ),
              onSelectionChanged: _saving ? null : (values) => _choose(values.single),
            ),
          ],
        ),
        if (_failed)
          Text('Could not save your header choice.', style: F.cap.copyWith(color: p.on(C.red))),
      ],
    );
  }
}

class _HeaderOption extends StatelessWidget {
  const _HeaderOption({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return DecoratedBox(
      decoration: BoxDecoration(color: p.card, borderRadius: R.headerChoice),
      child: Padding(
        padding: const EdgeInsets.all(S.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _HeaderIllustration(compact: compact),
          const SizedBox(height: S.x2),
          Text(compact ? 'Compact' : 'Standard',
              style: F.headerChoice.copyWith(color: p.ink)),
          const SizedBox(height: S.x1),
          Text(compact ? 'Status inside the day bar.' : 'Status line above the day bar.',
              style: F.headerChoiceHint.copyWith(color: p.ink3)),
        ]),
      ),
    );
  }
}

class _HeaderIllustration extends StatelessWidget {
  const _HeaderIllustration({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Container(
      height: 58,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: p.bg, borderRadius: R.headerIllustration),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact) ...[
            Container(height: 14, decoration: BoxDecoration(
              color: p.card2, borderRadius: R.headerIllustrationPill,
            )),
            const SizedBox(height: 6),
          ],
          ClipRRect(
            borderRadius: R.headerIllustrationBar,
            child: SizedBox(height: compact ? 22 : 16, child: ColoredBox(
              color: p.card2,
              child: compact ? FractionallySizedBox(
                widthFactor: .55,
                alignment: Alignment.centerLeft,
                child: ColoredBox(color: C.syncCalculate.withValues(alpha: .35)),
              ) : null,
            )),
          ),
        ],
      ),
    );
  }
}
