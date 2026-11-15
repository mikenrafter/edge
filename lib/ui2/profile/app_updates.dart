import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../l10n/app_localizations.dart';
import '../../notify/notification_service.dart';
import '../../sync/update_service.dart';
import '../../state/clock_format.dart';
import '../ui2.dart';
import 'profile.dart' show SetRow;

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
    };
String updateSummary(AppLocalizations l, UpdateSnapshot snapshot) {
  if (snapshot.phase == UpdatePhase.checking) return l.updatesChecking;
  if (snapshot.waiting) return l.updatesWaiting;
  for (final source in ReleaseSource.values.reversed) {
    final result = snapshot.sources[source];
    if (result?.candidate != null && result!.error == null && !result.current) {
      final candidate = result.candidate!;
      return '${candidate.separateApp ? l.updatesOfficialNew : l.updatesAvailable} · ${l.updatesReleaseLabel(source == ReleaseSource.fork ? l.updatesFork : l.updatesOfficial, candidate.tag, candidate.prerelease ? l.updatesPrerelease : l.updatesStable)}${candidate.separateApp ? ' · ${l.updatesSeparateApp}' : ''}';
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

/// Shared by Settings and the pilot renders; it never changes its place.
class AppUpdatesRow extends StatelessWidget {
  const AppUpdatesRow({super.key, required this.snapshot, this.onTap});
  final UpdateSnapshot snapshot;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: 24 + MediaQuery.textScalerOf(context).scale(64),
      ),
      child: SetRow(
        LucideIcons.refreshCw,
        C.blue,
        l.updatesTitle,
        sub: updateSummary(l, snapshot),
        onTap: onTap,
      ),
    );
  }
}

class AppUpdatesScreen extends StatefulWidget {
  const AppUpdatesScreen({super.key, required this.service});
  final UpdateService service;
  @override
  State<AppUpdatesScreen> createState() => _AppUpdatesScreenState();
}

class _AppUpdatesScreenState extends State<AppUpdatesScreen> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.updatesErrorStorage),
          ),
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.updatesTitle)),
      body: AnimatedBuilder(
        animation: widget.service,
        builder: (context, _) {
          final snapshot = widget.service.snapshot;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
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
                          // Opt-out remains available while a metadata request is in flight.
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
                child: OutlinedButton(
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
              if (snapshot.enabled)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _run(() async {
                      // This is the only update flow that may request OS permission.
                      await NotificationService.instance.ensurePermission();
                    }),
                    child: Text(l.updatesPermission),
                  ),
                ),
              if (snapshot.waiting) Text(l.updatesWaiting),
              for (final source in ReleaseSource.values.reversed)
                _source(context, source, snapshot.sources[source]),
            ],
          );
        },
      ),
    );
  }

  Widget _source(
    BuildContext context,
    ReleaseSource source,
    SourceUpdate? result,
  ) {
    final l = AppLocalizations.of(context)!;
    final candidate = result?.candidate;
    final time = result?.checkedAt?.toLocal();
    final retry = result?.retryAt?.toLocal();
    // Date and clock use the same locale/12–24h preferences as the rest of Settings.
    String date(DateTime t) =>
        '${MaterialLocalizations.of(context).formatMediumDate(t)} ${formatClockMinute(t.hour * 60 + t.minute)}';
    return Card(
      margin: const EdgeInsets.only(top: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              source == ReleaseSource.fork ? l.updatesFork : l.updatesOfficial,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(source.repository),
            const SizedBox(height: 8),
            if (result?.error != null) Text(updateErrorText(l, result!.error!)),
            if (candidate != null) ...[
              if (result!.error != null) Text(l.updatesStale),
              Text(
                l.updatesReleaseLabel(
                  source == ReleaseSource.fork
                      ? l.updatesFork
                      : l.updatesOfficial,
                  candidate.tag,
                  candidate.prerelease ? l.updatesPrerelease : l.updatesStable,
                ),
              ),
              if (candidate.separateApp) Text(l.updatesSeparateApp),
              if (result.current) Text(l.updatesCurrent),
              TextButton(
                onPressed: () async {
                  final opened = await UpdateService.openRelease(
                    candidate.page.toString(),
                  );
                  if (!opened && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.updatesOpenFailed)),
                    );
                  }
                },
                child: Text(l.updatesOpenRelease),
              ),
            ] else if (result?.error == null)
              Text(l.updatesNotChecked),
            if (candidate == null && result?.releasePage != null)
              TextButton(
                onPressed: () async {
                  final opened = await UpdateService.openRelease(
                    result!.releasePage.toString(),
                  );
                  if (!opened && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.updatesOpenFailed)),
                    );
                  }
                },
                child: Text(l.updatesOpenRelease),
              ),
            if (time != null) Text(l.updatesLastChecked(date(time))),
            if (retry != null) Text(l.updatesRetryAfter(date(retry))),
          ],
        ),
      ),
    );
  }
}
