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

import '../../health/health_import_state.dart' show storeName;
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/locale_controller.dart';
import '../ui2.dart';
import 'devices.dart';
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

/// A titled card whose rows open and close behind an explicit header tap. It
/// starts expanded: every setting is visible until the person folds a section
/// away. The header always stays in place, so a group never appears or moves
/// because some setting elsewhere changed; only this header's own tap changes
/// its height. Folded, [summary] stays under the title as one line, so a closed
/// section still says what is inside it.
class SettingsAccordion extends StatefulWidget {
  const SettingsAccordion(this.title,
      {super.key,
      required this.children,
      this.summary,
      this.initiallyExpanded = true});
  final String title;
  final List<Widget> children;
  final String? summary;
  final bool initiallyExpanded;

  @override
  State<SettingsAccordion> createState() => _SettingsAccordionState();
}

class _SettingsAccordionState extends State<SettingsAccordion> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final summary = widget.summary;
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          Pressable(
            onTap: () => setState(() => _open = !_open),
            semanticLabel: '${widget.title}, ${_open ? 'expanded' : 'collapsed'}',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
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
            for (final row in widget.children) ...[
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
      {super.key, this.sub = '', this.enabled = true});
  final String title, sub;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// 8K: false keeps the row in the list, dimmed, with its switch inert.
  final bool enabled;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: F.body.copyWith(color: p.ink)),
            if (sub.isNotEmpty) Text(sub, style: F.over.copyWith(color: p.ink3)),
          ]),
        ),
        const SizedBox(width: S.x2),
        Switch(value: value, onChanged: enabled ? onChanged : null),
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

/// The one way into the profile stack. Home's avatar calls this — profile is
/// a pushed route, never a sixth tab.
void openProfile(BuildContext c) => goto(c, const ProfileHome());

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

// ══════════════════ 1 · PROFILE HOME ══════════════════

/// What the profile screen still shows: who you are, how many sources are
/// live, and how much room the data takes.
///
/// The workouts / records / days / sessions counters are gone with the tile
/// that displayed them. They cost a `getRecords()` and a whole year-of-workouts
/// query on every open, so leaving the fields behind would have kept paying for
/// numbers nobody reads.
class ProfileStats {
  final String? name;
  final int sources;
  final int? storageBytes;

  const ProfileStats({this.name, this.sources = 0, this.storageBytes});
}

class ProfileHome extends StatefulWidget {
  const ProfileHome({super.key});

  @override
  State<ProfileHome> createState() => _ProfileHomeState();
}

class _ProfileHomeState extends State<ProfileHome> {
  /// Re-read after every screen this one pushes. It used to be a single
  /// `late final` Future, so pairing a band from My sources (which auto-pops
  /// straight back here) left the row reading "0 sources", and an import or a
  /// reset left Storage on the old size until the screen was left and
  /// re-entered.
  late Future<ProfileStats> _stats = _load();

  Future<ProfileStats> _load() async {
    final app = context.read<AppState>();
    // Storage moved into Settings (8AE), which reads the size itself; the
    // profile screen no longer pays for a file stat it does not draw.
    return ProfileStats(
        name: app.user?['name'] as String?,
        sources: liveSources(app).length);
  }

  Future<void> _open(BuildContext c, Widget w) async {
    await goto(c, w);
    if (mounted) setState(() => _stats = _load());
  }

  @override
  Widget build(BuildContext c) => FutureBuilder<ProfileStats>(
        future: _stats,
        builder: (c, snap) => ProfileHomeView(
          stats: snap.data,
          onDevices: () => _open(c, const MyDevices()),
          onSettings: () => _open(c, const MoreSettings()),
        ),
      );
}

class ProfileHomeView extends StatelessWidget {
  /// Null while the counts are still being read — the numbers are absent, not
  /// zero, and a zero rendered during a load is a wrong number on screen.
  final ProfileStats? stats;
  final VoidCallback? onDevices, onSettings;

  const ProfileHomeView(
      {super.key, this.stats, this.onDevices, this.onSettings});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final s = stats;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.profileTitle ?? 'Profile'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                const SizedBox(height: S.x4),
                settingsGroup(c, l?.profileQuickAccessGroup ?? 'Quick access', [
                  SetRow(LucideIcons.watch, C.blue,
                      l?.profileMyDevices ?? 'My devices',
                      sub: s == null
                          ? ''
                          : (l?.profileSourcesCount(s.sources) ??
                              '${s.sources} source${s.sources == 1 ? '' : 's'}'),
                      onTap: onDevices),
                  // The one door to everything else (8AE): profile, language,
                  // storage, the coach and the developer tools all moved into
                  // Settings, grouped by task.
                  SetRow(LucideIcons.settings, C.n500,
                      l?.settingsNavTitle ?? 'Settings',
                      sub: l?.profileMoreSettingsSub(storeName) ??
                          'Import from $storeName, export, backup, units, '
                              'privacy, reset',
                      onTap: onSettings),
                ]),
                settingsGroup(c, l?.profileCommunityGroup ?? 'Community', [
                  SetRow.brand(brandGlyph('assets/icons/github.svg'), C.n500,
                      l?.profileGithubTitle ?? 'GitHub',
                      sub: l?.profileGithubSub ??
                          'Star the project to show support.',
                      onTap: () => open3rdPartyLink(kGithubUrl)),
                  SetRow.brand(brandGlyph('assets/icons/reddit.svg'), C.orange,
                      l?.profileRedditTitle ?? 'Reddit',
                      sub: l?.profileRedditSub ??
                          'Join r/OpenStrap to share results and ask questions.',
                      onTap: () => open3rdPartyLink(kRedditUrl)),
                  SetRow.brand(brandGlyph('assets/icons/discord.svg'),
                      C.indigo, l?.profileDiscordTitle ?? 'Discord',
                      sub: l?.profileDiscordSub ??
                          'Chat with other users and the developers.',
                      onTap: () => open3rdPartyLink(kDiscordUrl)),
                  SetRow(LucideIcons.heartHandshake, C.pink,
                      l?.profileSponsorTitle ?? 'Sponsor',
                      sub: l?.profileSponsorSub ??
                          'This is a free, open-source project. Sponsoring funds development.',
                      onTap: () => open3rdPartyLink(kSponsorUrl)),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }

}
