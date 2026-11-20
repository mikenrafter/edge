import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme_controller.dart';
import '../grammar.dart' show NavBar, Pressable;
import '../home_header.dart';
import '../theme.dart';
import 'profile.dart' show SetRow;

class HomeHeaderAppearance extends StatelessWidget {
  const HomeHeaderAppearance({super.key});

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final theme = c.watch<ThemeController>();
    return Scaffold(
      backgroundColor: P.of(c).bg,
      body: SafeArea(child: Column(children: [
        NavBar(l?.settingsAppearanceRowTitle ?? 'Appearance'),
        Expanded(child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            SetRow(LucideIcons.sun, C.yellow,
              l?.settingsAppearanceRowTitle ?? 'Appearance',
              value: theme.choice.label,
              onTap: () => theme.setChoice(AppThemeChoice.values[
                (theme.choice.index + 1) % AppThemeChoice.values.length
              ]),
            ),
            const SizedBox(height: 20),
            const HomeHeaderChoice(),
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
    final compact = HomeHeader.compact;
    TextSpan bold(String value) => TextSpan(text: value,
      style: TextStyle(color: p.ink, fontWeight: FontWeight.w600));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Header', style: F.n17.copyWith(color: p.ink)),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _HeaderOption(
            compact: false, selected: !compact, onTap: _saving ? null : () => _choose(false),
          )),
          const SizedBox(width: 10),
          Expanded(child: _HeaderOption(
            compact: true, selected: compact, onTap: _saving ? null : () => _choose(true),
          )),
        ]),
        if (compact) ...[
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(color: p.card, borderRadius: R.rMd),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text.rich(
                TextSpan(children: [
                  bold('‹ ›'), const TextSpan(text: ' change the day, as before\n'),
                  bold('Long press'), const TextSpan(text: ' the bar for sync details\n'),
                  bold('Colour'), const TextSpan(text: ' behind the date: '),
                  TextSpan(text: 'green', style: TextStyle(color: p.on(C.green))),
                  const TextSpan(text: ' downloading, '),
                  TextSpan(text: 'purple', style: TextStyle(color: p.on(C.syncCalculate))),
                  const TextSpan(text: ' calculating'),
                ]),
                style: F.cap.copyWith(height: 1.7, color: p.ink2),
              ),
            ),
          ),
        ],
        if (_failed) ...[
          const SizedBox(height: 12),
          Text('Could not save your header choice.', style: F.cap.copyWith(color: p.on(C.red))),
        ],
      ],
    );
  }
}

class _HeaderOption extends StatelessWidget {
  const _HeaderOption({required this.compact, required this.selected, this.onTap});
  final bool compact, selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final accent = p.on(C.syncCalculate);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Pressable(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: R.headerChoice,
            border: Border.all(color: selected ? accent : Colors.transparent),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _HeaderIllustration(compact: compact),
              const SizedBox(height: 8),
              Row(children: [
                Container(
                  width: 16, height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(width: 2, color: selected ? accent : p.ink3),
                  ),
                  alignment: Alignment.center,
                  child: selected ? DecoratedBox(
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                    child: const SizedBox.square(dimension: 7),
                  ) : null,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(compact ? 'Compact' : 'Standard',
                  style: F.headerChoice.copyWith(color: p.ink))),
              ]),
              const SizedBox(height: 4),
              Text(compact ? 'Status inside the day bar.' : 'Status line above the day bar.',
                style: F.headerChoiceHint.copyWith(color: p.ink3)),
            ]),
          ),
        ),
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
