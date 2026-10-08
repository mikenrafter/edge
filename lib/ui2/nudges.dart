// Soft, dismissible community asks — never a blocking dialog, never sticky.
// Two independent nudges (join Discord / support the project on GitHub
// Sponsors), each shown at most once per cooldown and never again once the
// user says so, via the same `Prefs` facade every other one-time UI flag
// uses. Both can be up at once, stacked — each is dismissed on its own.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import '../state/capabilities.dart';
import '../state/capabilities_scope.dart';
import '../state/prefs.dart';
import 'ui2.dart';

enum _Ask { discord, donate }

/// Home renders one of these per eligible ask, right under the rings.
class CommunityNudge extends StatefulWidget {
  const CommunityNudge({super.key});

  /// Test hook: forget this launch's dismissals, as a new process would.
  @visibleForTesting
  static void debugResetSession() => _CommunityNudgeState._sessionHidden.clear();

  /// Test seam: the clock the cooldown and "last shown" stamp read, epoch
  /// milliseconds. Null (the default) is the real clock.
  @visibleForTesting
  static int Function()? debugNowMs;

  static int _nowMs() => (debugNowMs ?? _systemNowMs)();
  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  State<CommunityNudge> createState() => _CommunityNudgeState();
}

class _CommunityNudgeState extends State<CommunityNudge> {
  // Two weeks between reappearances of a snoozed ask — long enough that it
  // never reads as nagging, short enough it is not gone for good on a tap
  // that was just a slip.
  static const _cooldownMs = 14 * 24 * 60 * 60 * 1000;

  // Asks dismissed during this launch. Developer mode ignores the stored
  // dismissal and cooldown (below), so without this a remount of the card —
  // which Home causes whenever its list changes shape during a recalculation —
  // would bring a dismissed ask straight back. Process memory only: a new
  // launch shows the asks again.
  static final Set<String> _sessionHidden = {};

  static String _dismissedKey(_Ask a) => 'nudge.${a.name}.dismissed';
  static String _lastShownKey(_Ask a) => 'nudge.${a.name}.last_shown_ms';

  static bool _eligible(_Ask a, {required bool devMode}) {
    // Dismissed this launch: stays dismissed, developer mode or not.
    if (_sessionHidden.contains(a.name)) return false;
    // Developer mode is someone deliberately testing the app, not a real
    // reader being nagged — silencing or a cooldown here would just make
    // this unreachable on every build after the first tap.
    if (devMode) return true;
    if (Prefs.getBool(_dismissedKey(a), false)) return false;
    final last = Prefs.getInt(_lastShownKey(a), 0);
    return CommunityNudge._nowMs() - last > _cooldownMs;
  }

  // Discord above the sponsor ask when both are due — joining a community
  // is a smaller thing to ask for than money.
  late List<_Ask> _asks;

  @override
  void initState() {
    super.initState();
    final devMode = context.capsRead.has(Feature.developerMode);
    _asks = [for (final a in _Ask.values) if (_eligible(a, devMode: devMode)) a];
    // Mark each shown ask as seen NOW, not only on snooze/silence — otherwise
    // the cooldown never actually starts and leaving Home without tapping
    // anything shows the same ask again on the very next rebuild.
    for (final a in _asks) {
      Prefs.setInt(_lastShownKey(a), CommunityNudge._nowMs());
    }
  }

  void _snooze(_Ask a) {
    _sessionHidden.add(a.name);
    Prefs.setInt(_lastShownKey(a), CommunityNudge._nowMs());
    _hide(a);
  }

  void _silence(_Ask a) {
    _sessionHidden.add(a.name);
    Prefs.setBool(_dismissedKey(a), true);
    _hide(a);
  }

  void _hide(_Ask a) {
    // The card's CTA awaits open3rdPartyLink before calling this — if the
    // widget tree was torn down while that was in flight, setState here
    // would throw after dispose.
    if (!mounted) return;
    // Developer mode ignores the stored dismissal and cooldown on a new
    // launch (see _eligible), but a tap still hides the card for this one.
    setState(() => _asks.remove(a));
  }

  @override
  Widget build(BuildContext c) => Column(
      children: [for (final a in _asks) _AskCard(a, onSnooze: _snooze, onSilence: _silence)]);
}

class _AskCard extends StatelessWidget {
  final _Ask ask;
  final void Function(_Ask) onSnooze, onSilence;

  const _AskCard(this.ask, {required this.onSnooze, required this.onSilence});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final (glyph, color, title, body, cta, url) = switch (ask) {
      _Ask.discord => (
          brandGlyph('assets/icons/discord.svg'),
          C.indigo,
          l?.nudgeDiscordTitle ?? 'OpenStrap Discord',
          l?.nudgeDiscordBody ??
              'Report bugs and ask other people running the same band '
              'on the OpenStrap Discord.',
          l?.nudgeDiscordCta ?? 'Join Discord',
          kDiscordUrl,
        ),
      _Ask.donate => (
          (Color tint) =>
              Icon(LucideIcons.heartHandshake, size: 16, color: tint),
          C.pink,
          l?.nudgeDonateTitle ?? 'Support OpenStrap',
          l?.nudgeDonateBody ??
              'OpenStrap is free and open source, with no subscription. '
              'Sponsorships fund ongoing maintenance.',
          l?.nudgeDonateCta ?? 'Support the project',
          kSponsorUrl,
        ),
    };

    return Padding(
      padding: const EdgeInsets.only(top: S.x5),
      child: Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(color: p.wash(color), borderRadius: R.rSm),
              child: glyph(p.on(color)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: F.body.copyWith(
                            color: p.ink, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(body, style: F.over.copyWith(color: p.ink3)),
                  ]),
            ),
            const SizedBox(width: S.x2),
            Pressable(
              onTap: () => onSnooze(ask),
              semanticLabel: l?.nudgeNotNow ?? 'Not now',
              child: Icon(LucideIcons.x, size: 16, color: p.ink3),
            ),
          ]),
          const SizedBox(height: S.x3),
          BigButton(cta,
              icon: LucideIcons.externalLink,
              color: color,
              soft: true,
              onTap: () async {
                // Only silence permanently once the link actually opened —
                // a failed launch (no app registered, no browser default)
                // should not look "acted on".
                if (await open3rdPartyLink(url)) {
                  onSilence(ask);
                } else {
                  onSnooze(ask);
                }
              }),
          const SizedBox(height: S.x2),
          Center(
            child: Pressable(
              onTap: () => onSilence(ask),
              semanticLabel: l?.nudgeDontShowAgain ?? "Don't show this again",
              child: Text(l?.nudgeDontShowAgain ?? "Don't show this again",
                  style: F.over.copyWith(
                      color: p.ink3, decoration: TextDecoration.underline)),
            ),
          ),
        ]),
      ),
    );
  }
}
