// AppShell owns tab selection, history and requested dates.
// Four domains, with an optional Settings tab.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import '../state/prefs.dart';
import 'profile/settings.dart' show MoreSettings;
import 'grammar.dart';
import 'shared_slot.dart';
import 'theme.dart';

/// The four primary destinations, in bar order.
enum ShellDomain {
  today('Today', LucideIcons.house, C.domHome),
  sleep('Sleep', LucideIcons.moon, C.domSleep),
  activity('Activity', LucideIcons.dumbbell, C.domMove),
  health('Health', LucideIcons.heartPulse, C.domHealth);

  const ShellDomain(this.label, this.icon, this.accent);

  final String label;
  final IconData icon;

  /// [label] in the user's language. Own keys rather than the screen titles,
  /// so two tabs can never end up with the same translated word.
  String title(BuildContext c) {
    final l = AppLocalizations.of(c);
    return switch (this) {
          ShellDomain.today => l?.tabToday,
          ShellDomain.sleep => l?.tabSleep,
          ShellDomain.activity => l?.tabActivity,
          ShellDomain.health => l?.tabHealth,
        } ??
        label;
  }

  /// The domain's pigment. Use `P.of(context).on(accent)` for text and
  /// `.fill(accent)` for a filled surface — the raw value is not AA-safe.
  final Color accent;
}

/// Carried into detail routes by the shared navigation helpers, so a domain
/// link can return to its shell even from a pushed detail.
class ShellNavigation extends InheritedWidget {
  final void Function(ShellDomain domain, {String? date}) selectDomain;
  const ShellNavigation({super.key, required this.selectDomain, required super.child});

  static ShellNavigation? maybeOf(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<ShellNavigation>();

  static Widget carry(BuildContext c, Widget child) {
    final nav = maybeOf(c);
    return nav == null ? child : ShellNavigation(selectDomain: nav.selectDomain, child: child);
  }

  @override
  bool updateShouldNotify(ShellNavigation oldWidget) =>
      selectDomain != oldWidget.selectDomain;
}

/// A domain's requested calendar date. The shell retains it while tabs park.
class ShellDate extends InheritedWidget {
  final String? date;
  final int revision;
  const ShellDate({super.key, this.date, required this.revision, required super.child});
  static ShellDate? maybeOf(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<ShellDate>();
  @override
  bool updateShouldNotify(ShellDate oldWidget) => revision != oldWidget.revision;
}

class AppShell extends StatefulWidget {
  /// Builds the body of one domain. Called lazily — a tab is not built until
  /// it is first selected, then kept alive by the [IndexedStack].
  final Widget Function(BuildContext context, ShellDomain domain) builder;

  final ShellDomain initial;

  /// Notified on every tab change, including a re-tap of the current tab
  /// (which domains conventionally use to scroll to top) and a return via Back.
  final void Function(ShellDomain domain)? onSelect;

  /// Pinned between the domain and the tab bar, above every tab. This is not
  /// a general slot — it exists for state that is RUNNING and is not on
  /// screen, which today means a minimised workout. A domain's own content
  /// belongs inside the domain.
  final Widget? banner;

  const AppShell({
    super.key,
    required this.builder,
    this.initial = ShellDomain.today,
    this.onSelect,
    this.banner,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late ShellDomain _current = widget.initial;
  bool _settings = false;
  bool _settingsBuilt = false;
  final Map<ShellDomain, String?> _dates = {};
  final Map<ShellDomain, int> _dateRevisions = {};

  @override
  void initState() {
    super.initState();
    Prefs.settingsAsTabRevision.addListener(_settingsChanged);
  }

  @override
  void dispose() {
    Prefs.settingsAsTabRevision.removeListener(_settingsChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!Prefs.settingsAsTabOn) {
      _settings = false;
      _settingsBuilt = false;
    }
  }

  void _settingsChanged() => setState(() {
    if (!Prefs.settingsAsTabOn) {
      _settings = false;
      _settingsBuilt = false;
    }
  });

  void _selectDomain(ShellDomain domain, {String? date}) {
    _dates[domain] = date;
    _dateRevisions[domain] = (_dateRevisions[domain] ?? 0) + 1;
    _select(domain);
    final route = ModalRoute.of(context);
    if (route != null) Navigator.of(context).popUntil((r) => r == route);
  }

  void _selectSettings() => setState(() {
    _settings = true;
    _settingsBuilt = true;
  });
  late final Set<ShellDomain> _built = {widget.initial};
  // Tabs are kept alive, not pushed onto the Navigator. Keep their history
  // here so Android Back can return to the previous tab. A restored tab or
  // cold-launch deep link has Today as its way back into the app.
  late final List<ShellDomain> _history = [
    if (widget.initial != ShellDomain.today) ShellDomain.today,
  ];

  void _select(ShellDomain d) {
    setState(() {
      _settings = false;
      // Each tab at most once, most recent last, so switching back and forth
      // between two tabs does not add a Back press per switch. Today stays in
      // as the way back into the app even while it is the tab on screen.
      if (d != _current) {
        _history.remove(_current);
        // Leaving Today puts it back at the bottom, never on top: it is the
        // last stop before Back leaves the app.
        if (_current == ShellDomain.today) {
          _history.insert(0, _current);
        } else {
          _history.add(_current);
        }
        if (d != ShellDomain.today) _history.remove(d);
      }
      _current = d;
      _built.add(d);
    });
    widget.onSelect?.call(d);
  }

  void _back() {
    if (_settings) {
      setState(() => _settings = false);
      return;
    }
    if (_history.isEmpty) return;
    setState(() {
      _current = _history.removeLast();
      _built.add(_current);
    });
    widget.onSelect?.call(_current);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return ShellNavigation(
      selectDomain: _selectDomain,
      child: PopScope<Object?>(
      canPop: !_settings && _history.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: _settings ? 4 : _current.index,
                  children: [
                    // An unvisited tab is an empty box, not a built screen — the
                    // old shell built all forty screens' worth of state on launch.
                    for (final d in ShellDomain.values)
                      if (_built.contains(d))
                        // A parked tab keeps its state but stops its tickers and
                        // its revision reloads (see RevisionReload).
                        TickerMode(
                          enabled: !_settings && d == _current,
                          child: ShellDate(
                            date: _dates[d], revision: _dateRevisions[d] ?? 0,
                            child: Builder(builder: (c) => widget.builder(c, d))),
                        )
                      else
                        const SizedBox.shrink(),
                    if (Prefs.settingsAsTabOn)
                      _settingsBuilt
                          ? TickerMode(enabled: _settings, child: const MoreSettings(embedded: true))
                          : const SizedBox.shrink(),
                  ],
                ),
              ),
              if (widget.banner != null) widget.banner!,
            ],
          ),
        ),
        bottomNavigationBar:
            SharedSlot('tabbar', child: _TabBar(current: _settings ? null : _current, onTap: _select, onSettings: Prefs.settingsAsTabOn ? _selectSettings : null)),
      ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final ShellDomain? current;
  final ValueChanged<ShellDomain> onTap;

  final VoidCallback? onSettings;

  const _TabBar({required this.current, required this.onTap, this.onSettings});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: SafeArea(
        top: false,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in ShellDomain.values)
                Expanded(
                  child: _Tab(
                    domain: d,
                    on: d == current,
                    onTap: () => onTap(d),
                  ),
                ),
              if (onSettings != null)
                Expanded(child: Semantics(
                  key: const ValueKey('apk1-settings-tab'),
                  selected: current == null,
                  child: Pressable(
                    semanticLabel: AppLocalizations.of(c)?.settingsNavTitle ?? 'Settings',
                    onTap: onSettings,
                    child: ExcludeSemantics(child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(LucideIcons.settings, size: 20,
                            color: current == null ? p.on(C.domHome) : p.ink3),
                        const SizedBox(height: 3),
                        Text(AppLocalizations.of(c)?.settingsNavTitle ?? 'Settings',
                            textAlign: TextAlign.center,
                            style: F.over.copyWith(color: p.ink3)),
                      ]),
                    )),
                  ),
                )),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final ShellDomain domain;
  final bool on;
  final VoidCallback onTap;

  const _Tab({required this.domain, required this.on, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = on ? p.on(domain.accent) : p.ink3;
    final label = domain.title(c);
    return Semantics(
      selected: on,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
            AnimatedContainer(
              duration: motion(c, Motion.base),
              padding: EdgeInsets.symmetric(
                horizontal: on ? S.x3 : 0,
                vertical: S.x1,
              ),
              decoration: BoxDecoration(
                color: on ? p.wash(domain.accent) : const Color(0x00000000),
                borderRadius: R.rPill,
              ),
              child: Icon(domain.icon, size: 20, color: ink),
            ),
              const SizedBox(height: 3),
              Text(
                label,
                textAlign: TextAlign.center,
              style: F.over.copyWith(
                color: ink,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
