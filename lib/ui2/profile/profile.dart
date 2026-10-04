// Profile.
//
// Reached from the Home avatar, never a sixth tab — the shell has five
// destinations and the type system says so.
//
// The reference design had a Premium badge and a Following/Followers pair.
// Both are gone, and not for lack of screen space: there is no account and no
// social graph, so a follower count would have to be invented and a premium
// tier would have to be sold. What replaces them is what this app actually
// knows — how much it has measured, and from what.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../settings/settings_repository.dart';
import '../../state/locale_controller.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'settings.dart';

// ══════════════════ shared list furniture ══════════════════

/// One row in a settings list. Shared by all three profile screens.
class SetRow extends StatelessWidget {
  final IconData? icon;
  final Color color;
  final String title, sub, value;
  final bool danger, chevron;

  /// 8K: a row that does not apply right now stays in the list, dimmed and
  /// inert, rather than appearing and disappearing with another setting. Say
  /// why in [sub] when the reason is not obvious.
  final bool enabled;
  final VoidCallback? onTap;

  /// A brand mark in place of [icon] — Lucide has no GitHub/Discord/Reddit
  /// logo, and a generic glyph standing in for one of those is worse than
  /// the extra param. Sized and tinted the same as the [Icon] it replaces.
  final Widget Function(Color tint)? glyph;

  const SetRow(IconData this.icon, this.color, this.title,
      {super.key,
      this.sub = '',
      this.value = '',
      this.danger = false,
      this.chevron = true,
      this.enabled = true,
      this.onTap})
      : glyph = null;

  const SetRow.brand(this.glyph, this.color, this.title,
      {super.key,
      this.sub = '',
      this.value = '',
      this.danger = false,
      this.chevron = true,
      this.enabled = true,
      this.onTap})
      : icon = null;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final accent = danger ? C.red : color;
    final row = Pressable(
      onTap: enabled ? onTap : null,
      semanticLabel: sub.isEmpty ? title : '$title. $sub',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: p.wash(accent), borderRadius: R.rSm),
            child: glyph != null
                ? glyph!(p.on(accent))
                : Icon(icon, size: 16, color: p.on(accent)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: F.body.copyWith(color: danger ? p.on(C.red) : p.ink)),
              if (value.isNotEmpty && bigText(c))
                Text(value,
                    style: F.cap.copyWith(
                        color: p.ink3, fontWeight: FontWeight.w600)),
              if (sub.isNotEmpty)
                Text(sub, style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          // THE ROW RULE (see MetricRow): the title is the only flexible part,
          // so every value in a settings list ends on one right edge. Two flex
          // children would split the width by ratio and break that column.
          // The value moves UNDER the title at accessibility sizes instead —
          // "2026-08-16 04:12" is arbitrary-length, and at 3.1× it pushed
          // itself and the chevron off the right of every settings screen.
          if (value.isNotEmpty && !bigText(c)) ...[
            const SizedBox(width: S.x2),
            Text(value, style: F.cap.copyWith(color: p.ink3)),
          ],
          if (chevron && !danger) ...[
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: 17, color: p.ink3),
          ],
        ]),
      ),
    );
    return enabled ? row : Opacity(opacity: kDisabledOpacity, child: row);
  }
}

/// How far a disabled settings row is dimmed (8K).
const double kDisabledOpacity = .45;

/// A titled card of [SetRow]s, hairline-separated.
Widget settingsGroup(BuildContext c, String title, List<Widget> rows) {
  final p = P.of(c);
  return Section(
    title,
    Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i < rows.length - 1) Divider(color: p.line, height: 1),
        ],
      ]),
    ),
  );
}

/// The app-pref key under which an accordion remembers whether it is open. [id]
/// is the screen and section as stable ids ("settings_band"), never the
/// translated title, so the answer survives a change of language.
String accordionPrefKey(String id) => 'accordion_$id';

/// A titled card whose rows open and close behind an explicit header tap. It
/// starts expanded: every setting is visible until the person folds a section
/// away. The header always stays in place, so a group never appears or moves
/// because some setting elsewhere changed; only this header's own tap changes
/// its height. Folded, [summary] stays under the title as one line, so a closed
/// section still says what is inside it.
///
/// With an [id] the open or folded state is remembered between visits, through
/// the app-prefs section of [SettingsRepository] (one bool per section, written
/// when it is toggled). A section that was never toggled starts as
/// [initiallyExpanded]. Without an [id] nothing is stored.
///
/// The open flag lives in a State, and the lists these sit in gain and lose
/// neighbours (a permission card, a "not connected" card). Positionally, a
/// neighbour would inherit the folded section's State and fold or open with it.
/// So this widget is a thin const description and the State sits in a card
/// keyed by [id]: an accordion that moves gets the State for its own id.
class SettingsAccordion extends StatelessWidget {
  const SettingsAccordion(this.title,
      {super.key,
      required this.children,
      this.summary,
      this.id,
      this.initiallyExpanded = true});
  final String title;
  final List<Widget> children;
  final String? summary;

  /// Screen id + section id, e.g. "settings_band". See [accordionPrefKey].
  final String? id;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => _SettingsAccordionCard(
      key: id == null ? null : ValueKey<String>('accordion_$id'), this);
}

class _SettingsAccordionCard extends StatefulWidget {
  const _SettingsAccordionCard(this.a, {super.key});
  final SettingsAccordion a;

  @override
  State<_SettingsAccordionCard> createState() => _SettingsAccordionState();
}

class _SettingsAccordionState extends State<_SettingsAccordionCard> {
  late bool _open = _remembered();

  /// Set once the person has toggled it: a stored answer that arrives after
  /// that must not undo what they just did.
  bool _toggled = false;

  /// The stored answer for this id, read synchronously from the start-up
  /// cache ([Prefs.ensureLoaded] runs before runApp), else [initiallyExpanded].
  /// Building in the remembered state on the first frame matters: a folded
  /// section built open and folded a frame later makes a long page shrink under
  /// a person who has already started scrolling it. Before the cache is loaded
  /// this is the default, and [_restore] still corrects it.
  bool _remembered() {
    final id = widget.a.id;
    if (id == null) return widget.a.initiallyExpanded;
    return Prefs.getBool(accordionPrefKey(id), widget.a.initiallyExpanded);
  }

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didUpdateWidget(_SettingsAccordionCard old) {
    super.didUpdateWidget(old);
    if (old.a.id == widget.a.id) return;
    // This State now belongs to another section: show that section's answer,
    // not the one it held, and let a read still in flight for the old id lapse.
    _toggled = false;
    _open = _remembered();
    _restore();
  }

  Future<void> _restore() async {
    final id = widget.a.id;
    if (id == null) return;
    bool? stored;
    try {
      stored = await SettingsRepository.instance.appBool(accordionPrefKey(id));
    } catch (_) {
      return; // Unreadable: keep today's default.
    }
    if (!mounted || widget.a.id != id || _toggled) return;
    final answer = stored ?? widget.a.initiallyExpanded;
    if (answer == _open) return;
    setState(() => _open = answer);
  }

  Future<void> _toggle() async {
    final open = !_open;
    setState(() {
      _toggled = true;
      _open = open;
    });
    final id = widget.a.id;
    if (id == null) return;
    try {
      await SettingsRepository.instance.update(
        (d) => d.setBool(accordionPrefKey(id), open),
        sections: const {},
      );
    } catch (_) {
      // The fold still happened on screen; it just will not be remembered.
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final summary = widget.a.summary;
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      // The card is drawn here rather than by Surface, which wraps its child in
      // an inert Pressable: the first Pressable inside an accordion is its
      // header, the only control a tap or a screen reader should find first.
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: S.x4),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: R.rLg,
          boxShadow: p.el(1),
        ),
        child: Column(children: [
          Pressable(
            onTap: _toggle,
            semanticLabel: '${widget.a.title}, ${_open ? 'expanded' : 'collapsed'}',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.a.title,
                            style: F.body.copyWith(
                                color: p.ink, fontWeight: FontWeight.w600)),
                        if (!_open && summary != null && summary.isNotEmpty)
                          Text(summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: F.over.copyWith(color: p.ink3)),
                      ]),
                ),
                Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                    size: 17, color: p.ink3),
              ]),
            ),
          ),
          if (_open)
            for (final row in widget.a.children) ...[
              Divider(color: p.line, height: 1),
              row,
            ],
        ]),
      ),
    );
  }
}

/// A label with a switch. The switch carries the state, so the row prints no
/// "On"/"Off" word that a screen would then have to count.
class SwitchRow extends StatelessWidget {
  const SwitchRow(this.title, this.value, this.onChanged,
      {super.key,
      this.sub = '',
      this.enabled = true,
      this.switchFirst = false});
  final String title, sub;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// 8K: false keeps the row in the list, dimmed, with its switch inert.
  final bool enabled;

  /// The switch leads the label instead of trailing it. For a switch that sits
  /// under another row's icon column (the phone's, in My devices), where it
  /// reads as that row's own control.
  final bool switchFirst;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final label = Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: F.body.copyWith(color: p.ink)),
        if (sub.isNotEmpty) Text(sub, style: F.over.copyWith(color: p.ink3)),
      ]),
    );
    final toggle = Switch(value: value, onChanged: enabled ? onChanged : null);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Row(children: [
        if (switchFirst) ...[toggle, const SizedBox(width: S.x3), label]
        else ...[label, const SizedBox(width: S.x2), toggle],
      ]),
    );
    return enabled ? row : Opacity(opacity: kDisabledOpacity, child: row);
  }
}

/// Push a screen, keeping the enclosing domain accent. Returns when it pops,
/// so a caller whose own numbers the pushed screen can change is able to
/// re-read them.
Future<void> goto(BuildContext c, Widget w) =>
    Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => w));

/// The one way into Settings from Home's Profile button. There is no profile
/// landing screen in between (8AF.7): Settings is the landing, and it is a
/// pushed route, never a sixth tab.
void openProfile(BuildContext c) => goto(c, const MoreSettings());

/// Display name for a language code, sourced from a small hardcoded table.
/// Add a row here when a contributor's `app_<code>.arb` lands — nothing else
/// to touch; the picker below only ever offers what [AppLocalizations]
/// actually has translations for.
const Map<String, String> _kLanguageNames = {
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'zh': '中文',
  'hi': 'हिन्दी',
};

String languageLabel(BuildContext c, String? code) => code == null
    ? (AppLocalizations.of(c)?.languageSystemDefault ?? 'System default')
    : (_kLanguageNames[code] ?? code);

Future<void> pickLanguage(BuildContext c) async {
  final p = P.of(c);
  final ctrl = c.read<LocaleController>();
  final options = <String?>[null, ...AppLocalizations.supportedLocales.map((l) => l.languageCode)];
  await showModalBottomSheet<void>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final code in options)
            ListTile(
              title: Text(languageLabel(sheet, code), style: F.body.copyWith(color: p.ink)),
              trailing: ctrl.code == code
                  ? Icon(LucideIcons.check, size: 18, color: p.on(C.blue))
                  : null,
              onTap: () async {
                await ctrl.setCode(code);
                if (sheet.mounted) Navigator.of(sheet).pop();
              },
            ),
        ],
      ),
    ),
  );
}

/// Human-readable byte size. No dependency for four lines of arithmetic.
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 ? v.toStringAsFixed(1) : v.round()} ${units[i]}';
}
