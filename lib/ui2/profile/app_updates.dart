// App updates: the Settings row and the two source cards. Opens GitHub release
// pages only. There is no download, install or mode-switch control anywhere on
// this screen (owner rule: NO INSTALLS, EVER; guarded by test/guards).
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../notify/notification_service.dart';
import '../../state/clock_format.dart';
import '../../sync/update_coordinator.dart';
import '../ui2.dart';
import 'profile.dart' show SetRow;

/// A touch target is never smaller than this (Material minimum; `S.tap` alone
/// is 44).
const double kMinTarget = 48;

String updateErrorText(AppLocalizations l, UpdateError error) =>
    switch (error) {
      UpdateError.offline => l.updatesErrorOffline,
      UpdateError.badMetadata => l.updatesErrorMetadata,
      UpdateError.redirect => l.updatesErrorRedirect,
      UpdateError.rateLimited => l.updatesErrorRate,
      UpdateError.incomplete => l.updatesErrorIncomplete,
      UpdateError.noRelease => l.updatesErrorNoRelease,
      UpdateError.noAsset => l.updatesErrorNoAsset,
      UpdateError.network => l.updatesErrorNetwork,
      UpdateError.storage => l.updatesErrorStorage,
      UpdateError.scheduling => l.updatesErrorScheduling,
      UpdateError.refused => l.updatesErrorRefused,
      UpdateError.unidentified => l.updatesErrorUnidentified,
    };

String _sourceName(AppLocalizations l, ReleaseSource source) =>
    source == ReleaseSource.fork ? l.updatesFork : l.updatesOfficial;

String _release(AppLocalizations l, ReleaseCandidate c) => l.updatesReleaseLabel(
  _sourceName(l, c.source),
  c.tag,
  c.prerelease ? l.updatesPrerelease : l.updatesStable,
);

/// The one line Settings shows for [snapshot].
String updateSummary(AppLocalizations l, UpdateSnapshot snapshot) {
  if (snapshot.phase == UpdatePhase.checking) return l.updatesChecking;
  if (snapshot.waiting) return l.updatesWaiting;
  for (final source in ReleaseSource.values.reversed) {
    final result = snapshot.sources[source];
    if (result?.candidate != null &&
        result!.error == null &&
        result.candidate!.relation.announces) {
      final c = result.candidate!;
      return '${c.separateApp ? l.updatesOfficialNew : l.updatesAvailable}'
          ' · ${_release(l, c)}'
          '${c.separateApp ? ' · ${l.updatesSeparateApp}' : ''}';
    }
  }
  for (final result in snapshot.sources.values) {
    if (result.error != null) return updateErrorText(l, result.error!);
  }
  return switch (snapshot.phase) {
    UpdatePhase.off => l.updatesOff,
    UpdatePhase.notChecked => l.updatesNotChecked,
    UpdatePhase.current => l.updatesCurrent,
    UpdatePhase.available => l.updatesAvailable,
    UpdatePhase.error => l.updatesErrorStorage,
    UpdatePhase.checking => l.updatesChecking,
  };
}

/// Shared by Settings and the captures; it never changes its place.
class AppUpdatesRow extends StatelessWidget {
  const AppUpdatesRow({super.key, required this.snapshot, this.onTap});
  final UpdateSnapshot snapshot;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    // Settings is built without localizations in some hosts: English then.
    final l = AppLocalizations.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: 24 + MediaQuery.textScalerOf(context).scale(64),
      ),
      child: SetRow(
        LucideIcons.refreshCw,
        C.blue,
        l?.updatesTitle ?? 'App updates',
        sub: l == null ? 'Not checked' : updateSummary(l, snapshot),
        onTap: onTap,
      ),
    );
  }
}

/// The shared export route as this screen sees it (spec §2: one route, opened
/// from the update card and the Data row). No network request is made by it.
abstract interface class ExportRoute {
  void open(
    BuildContext context, {
    bool newerOfficialAvailable = false,
    DateTime? checkedAt,
  });
}

class AppUpdatesScreen extends StatefulWidget {
  const AppUpdatesScreen({
    super.key,
    required this.service,
    this.access,
    this.openAppSettings,
  });
  final UpdateCoordinator service;

  /// Reads the current permission/channel state without prompting. Defaults to
  /// the notification service.
  final Future<ReleaseAlertAccess> Function()? access;

  /// Opens the OS app-settings page; defaults to the notification service's.
  final Future<void> Function()? openAppSettings;

  /// SEAM for P3's shared export route. At merge, set this to an [ExportRoute]
  /// whose `open` calls P3's `openOfficialExport(context,
  /// newerOfficialAvailable:, checkedAt:)` (lib/ui2/profile/official_export.dart).
  /// Null until then, and the card entry is not shown.
  static ExportRoute? exportRoute;

  @override
  State<AppUpdatesScreen> createState() => _AppUpdatesScreenState();
}

class _AppUpdatesScreenState extends State<AppUpdatesScreen> {
  bool _busy = false;
  ReleaseAlertAccess? _access;

  @override
  void initState() {
    super.initState();
    _readAccess();
    // Say once that unreadable consent was reset to off.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.service.snapshot.authorizationReset) return;
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.updatesAuthorizationReset)),
      );
      try {
        await widget.service.acknowledgeReset();
      } catch (_) {}
    });
  }

  Future<void> _readAccess() async {
    ReleaseAlertAccess access;
    try {
      access = await (widget.access ?? NotificationService.instance.releaseAlertAccess)();
    } catch (_) {
      access = ReleaseAlertAccess.denied;
    }
    if (mounted) setState(() => _access = access);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.updatesErrorStorage)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    final l = AppLocalizations.of(context)!;
    var unmetered = false;
    try {
      unmetered = await widget.service.unmetered();
    } catch (_) {}
    if (!mounted) return;
    if (!unmetered) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(l.updatesCheckNow),
          content: Text(l.updatesMetered),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(MaterialLocalizations.of(c).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(l.updatesContinue),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    await _run(() => widget.service.check(manual: true));
  }

  Future<void> _allow() => _run(() async {
    // The only update flow that may request the OS permission, from a tap.
    await NotificationService.instance.ensurePermission();
    await _readAccess();
  });

  Future<void> _openPage(ReleasePage page) async {
    final l = AppLocalizations.of(context)!;
    final opened = await UpdateCoordinator.openRelease(page);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.updatesOpenFailed),
          action: SnackBarAction(
            label: l.updatesRetry,
            onPressed: () => _openPage(page),
          ),
        ),
      );
    }
  }

  Widget _target(Widget child) =>
      ConstrainedBox(constraints: const BoxConstraints(minHeight: kMinTarget, minWidth: kMinTarget), child: child);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.updatesTitle)),
      body: AnimatedBuilder(
        animation: widget.service,
        builder: (context, _) {
          final snapshot = widget.service.snapshot;
          final supported = widget.service.supported;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!supported) ...[
                Text(l.updatesUnsupported),
                for (final source in ReleaseSource.values.reversed)
                  _pageCard(context, source),
              ] else ...[
                Text(l.updatesConsent),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.updatesAutomatic),
                  value: snapshot.enabled,
                  onChanged: _busy && !snapshot.enabled
                      ? null
                      : (value) async {
                          if (!value) {
                            // Opt-out stays available while a request is in flight.
                            try {
                              await widget.service.setEnabled(false);
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(l.updatesErrorStorage)),
                                );
                              }
                            }
                          } else {
                            await _run(() async {
                              await widget.service.setEnabled(true);
                              await widget.service.check();
                            });
                          }
                        },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.updatesOfficialPrereleases),
                  value: snapshot.officialPrereleases,
                  onChanged: _busy
                      ? null
                      : (value) => _run(
                          () => widget.service.setOfficialPrereleases(value),
                        ),
                ),
                Text(l.updatesCheckOnce),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _target(
                    OutlinedButton(
                      onPressed: _busy || snapshot.phase == UpdatePhase.checking
                          ? null
                          : _check,
                      child: Text(
                        snapshot.phase == UpdatePhase.checking
                            ? l.updatesChecking
                            : l.updatesCheckNow,
                      ),
                    ),
                  ),
                ),
                if (snapshot.enabled) ..._permission(context, l),
                if (snapshot.waiting) Text(l.updatesWaiting),
                for (final source in ReleaseSource.values.reversed)
                  _source(context, source, snapshot.sources[source]),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Granted, denied or channel-muted, with the action that can change it.
  List<Widget> _permission(BuildContext context, AppLocalizations l) {
    final access = _access;
    if (access == null) return const [];
    final (text, canPrompt) = switch (access) {
      ReleaseAlertAccess.granted => (l.updatesPermissionGranted, false),
      ReleaseAlertAccess.denied => (l.updatesPermissionDenied, true),
      ReleaseAlertAccess.channelMuted => (l.updatesPermissionMuted, false),
    };
    return [
      const SizedBox(height: 8),
      Text(text),
      Wrap(
        children: [
          if (canPrompt)
            _target(
              TextButton(onPressed: _busy ? null : _allow, child: Text(l.updatesPermission)),
            ),
          if (access != ReleaseAlertAccess.granted)
            _target(
              TextButton(
                onPressed: () async {
                  await (widget.openAppSettings ??
                      NotificationService.instance.openSystemSettings)();
                },
                child: Text(l.updatesOpenSettings),
              ),
            ),
        ],
      ),
    ];
  }

  /// On a device that cannot identify itself: the two pages, nothing else.
  Widget _pageCard(BuildContext context, ReleaseSource source) {
    final l = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.only(top: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_sourceName(l, source), style: Theme.of(context).textTheme.titleMedium),
            Text(source.repository),
            _target(
              TextButton(
                onPressed: () => _openPage(ReleasePage.indexOf(source)),
                child: Text(l.updatesOpenRelease),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _source(BuildContext context, ReleaseSource source, SourceUpdate? result) {
    final l = AppLocalizations.of(context)!;
    final candidate = result?.candidate;
    final time = result?.checkedAt?.toLocal();
    final retry = result?.retryAt?.toLocal();
    // Date and clock follow the same locale and 12/24 h choice as Settings.
    String date(DateTime t) =>
        '${MaterialLocalizations.of(context).formatMediumDate(t)} ${formatClockMinute(t.hour * 60 + t.minute)}';
    final page = candidate?.page ?? result?.releasePage;
    return Card(
      margin: const EdgeInsets.only(top: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_sourceName(l, source), style: Theme.of(context).textTheme.titleMedium),
            Text(source.repository),
            const SizedBox(height: 8),
            if (result?.error != null) Text(updateErrorText(l, result!.error!)),
            if (candidate != null) ...[
              if (result!.error != null) Text(l.updatesStale),
              Text(_release(l, candidate)),
              ..._relation(l, candidate, result.error == null),
            ] else if (result?.error == null)
              Text(l.updatesNotChecked),
            if (candidate?.separateApp == true &&
                result!.error == null &&
                AppUpdatesScreen.exportRoute != null)
              _target(
                TextButton(
                  onPressed: () => AppUpdatesScreen.exportRoute!.open(
                    context,
                    newerOfficialAvailable: true,
                    checkedAt: result.checkedAt,
                  ),
                  child: Text(l.updatesExportEntry),
                ),
              ),
            if (page != null)
              _target(
                TextButton(
                  onPressed: () => _openPage(page),
                  child: Text(l.updatesOpenRelease),
                ),
              ),
            if (time != null) Text(l.updatesLastChecked(date(time))),
            if (retry != null) Text(l.updatesRetryAfter(date(retry))),
          ],
        ),
      ),
    );
  }

  List<Widget> _relation(AppLocalizations l, ReleaseCandidate c, bool fresh) {
    if (!fresh) return const [];
    return switch (c.relation) {
      ReleaseRelation.officialSeparateApp => [
        Text(l.updatesOfficialNew),
        Text(l.updatesSeparateApp),
      ],
      ReleaseRelation.officialInformational => [
        Text(l.updatesOfficialInformational(c.tag)),
      ],
      ReleaseRelation.forkNewer || ReleaseRelation.officialNewer => [
        Text(l.updatesAvailable),
      ],
      ReleaseRelation.forkCurrent || ReleaseRelation.officialCurrent => [
        Text(l.updatesCurrent),
      ],
      ReleaseRelation.unknown => [Text(l.updatesErrorUnidentified)],
    };
  }
}
