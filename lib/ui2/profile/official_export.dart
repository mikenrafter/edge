import 'dart:convert';
import 'official_export_skips.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../../data/backup_storage.dart';
import '../../data/official_export/coordinator.dart';
import '../../data/official_export/destination.dart';
import '../../data/official_export/profile.dart';
import '../../data/official_export/snapshot.dart';
import '../onboarding/welcome.dart' show askBackupPassphrase;
import '../ui2.dart';

Future<bool?> askOfficialRecovery(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _RecoveryDialog(),
  );
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog();
  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  bool _keep = true;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text(
      "Save a second file with data the official version doesn't yet support?",
    ),
    content: CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      value: _keep,
      onChanged: (value) => setState(() => _keep = value ?? true),
      title: const Text('Keep an encrypted fork recovery file'),
      subtitle: const Text(
        'Includes fork-only records, settings and saved files. If you decline, these remain only in this fork.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, _keep),
        child: const Text('Continue'),
      ),
    ],
  );
}

class OfficialExportScreen extends StatefulWidget {
  const OfficialExportScreen({super.key});
  @override
  State<OfficialExportScreen> createState() => _OfficialExportScreenState();
}

class _OfficialExportScreenState extends State<OfficialExportScreen>
    implements OfficialRecoveryChoice, OfficialExportProgress {
  var _coordinator = OfficialExportCoordinator();
  String _phase = 'ready';
  String? _stage, _message, _latest;
  int? _processed;
  bool _fresh = false;
  List<String> _files = [];
  OfficialExportReport? _report;

  @override
  Future<bool?> choose() async {
    if (!mounted) return false;
    return askOfficialRecovery(context);
  }

  @override
  void update(String stage, int? count) {
    if (mounted) {
      setState(() {
        _stage = stage;
        _processed = count;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _checkRelease();
  }

  Future<void> _checkRelease() async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(
              'https://api.github.com/repos/OpenStrap/edge/releases/latest',
            ),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final release = jsonDecode(response.body) as Map;
        if (mounted &&
            release['prerelease'] == false &&
            release['draft'] == false) {
          setState(() => _latest = release['tag_name'] as String?);
        }
      }
    } catch (_) {
      /* Offline exports keep their explicit, immutable target. */
    } finally {
      client.close();
    }
  }

  @override
  void dispose() {
    _coordinator.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (_phase == 'running' || !_fresh) return;
    _coordinator = OfficialExportCoordinator();
    setState(() {
      _phase = 'running';
      _stage = 'Choosing a folder';
      _message = null;
    });
    try {
      final OfficialDestination destination;
      if (Platform.isAndroid) {
        final folder = await AndroidBackupStorage.pick();
        if (folder == null) {
          if (mounted) setState(() => _phase = 'cancelled');
          return;
        }
        destination = AndroidOfficialDestination(folder);
      } else {
        final folder = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Save official export',
        );
        if (folder == null) {
          if (mounted) setState(() => _phase = 'cancelled');
          return;
        }
        destination = LocalOfficialDestination(Directory(folder));
      }
      if (!mounted) return;
      final passphrase = await askBackupPassphrase(context, creating: true);
      if (passphrase == null) {
        if (mounted) setState(() => _phase = 'cancelled');
        return;
      }
      final profile = await rootBundle.loadString(
        'assets/official_export/v0.11.3.json',
      );
      final temp = await getTemporaryDirectory();
      final result = await _coordinator.export(
        snapshot: const StrictOfficialSnapshot(),
        privateRoot: Directory('${temp.path}/official-export'),
        destination: destination,
        passphrase: passphrase,
        profileText: profile,
        recoveryChoice: this,
        onProgress: this,
      );
      if (!mounted) return;
      setState(() {
        switch (result) {
          case OfficialExportSaved():
            _phase = 'saved';
            _files = result.names;
            _message =
                'Folder: ${destination.label}. ${result.recoveryError ?? (result.recoveryKept ? 'Recovery file saved and verified.' : 'Recovery declined. Unsupported data remains in this fork.')}';
            _report = result.report;
          case OfficialExportCancelled():
            _phase = 'cancelled';
            _files = result.savedFiles;
          case OfficialExportFailed():
            _phase = 'failed';
            _message = '${result.stage}: ${result.reason}';
            _files = result.savedFiles;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _phase = 'failed';
          _message = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _phase != 'running',
    child: OfficialExportView(
      phase: _phase,
      stage: _stage,
      processed: _processed,
      message: _message,
      latestTag: _latest,
      fresh: _fresh,
      onFreshChanged: (v) => setState(() => _fresh = v ?? false),
      onStart: _start,
      onCancel: _coordinator.cancel,
      savedFiles: _files,
      report: _report,
    ),
  );
}

class OfficialExportView extends StatelessWidget {
  const OfficialExportView({
    super.key,
    this.phase = 'ready',
    this.stage,
    this.processed,
    this.message,
    this.savedFiles = const [],
    this.report,
    this.latestTag,
    this.fresh = false,
    this.onFreshChanged,
    this.onStart,
    this.onCancel,
  });
  final String phase;
  final String? stage, message, latestTag;
  final int? processed;
  final List<String> savedFiles;
  final OfficialExportReport? report;
  final bool fresh;
  final ValueChanged<bool?>? onFreshChanged;
  final VoidCallback? onStart, onCancel;
  @override
  Widget build(BuildContext c) {
    final palette = P.of(c);
    final skipLines = summarizeOfficialSkips(report?.skipped ?? const []);
    Widget paragraph(String text) => Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: Text(text, style: TextStyle(color: palette.ink, height: 1.45)),
    );
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: S.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: palette.ink,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: S.x2),
          ...children,
        ],
      ),
    );
    return Scaffold(
      backgroundColor: palette.bg,
      body: SafeArea(
        child: Column(
          children: [
            const NavBar(
              'Export for the official app',
              sub: 'Official $officialTargetTag',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(S.x4),
                children: [
                  Text(
                    'Official $officialTargetTag',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: S.x2),
                  paragraph(
                    'Pilot export for a fresh official install. Keep Edge Dev installed until you verify your imported history.',
                  ),
                  if (latestTag != null && isNewerOfficialRelease(latestTag!))
                    paragraph(
                      'A newer official release ($latestTag) is available. This file still targets $officialTargetTag. Update the fork for a newly tested exporter.',
                    ),
                  if (phase == 'running')
                    section(stage ?? 'Preparing official history', [
                      if (processed != null)
                        paragraph('$processed processed in this stage'),
                      paragraph(
                        'The file is complete only after it is saved and read back for verification.',
                      ),
                      OutlinedButton(
                        onPressed: onCancel,
                        child: const Text('Cancel export'),
                      ),
                    ])
                  else if (phase == 'failed')
                    section('Export could not finish', [
                      paragraph(
                        message ??
                            'No completed file was published. Your fork data is unchanged.',
                      ),
                    ])
                  else if (phase == 'cancelled')
                    section('Export cancelled', [
                      paragraph(
                        'Your fork data is unchanged. Any verified files already saved are listed below.',
                      ),
                    ])
                  else if (phase == 'saved')
                    section('Files saved and verified', [
                      for (final file in savedFiles) paragraph(file),
                      if (message != null) paragraph(message!),
                    ])
                  else
                    section('What transfers', [
                      paragraph(
                        'Journal, labs, nutrition, medications, workouts, sleep edits, saved measurements and supported recordings.',
                      ),
                      paragraph(
                        'Fork daily scores are cleared. The official app rebuilds supported days from the exact recordings still available.',
                      ),
                    ]),
                  if (phase != 'saved' && savedFiles.isNotEmpty)
                    section('Already saved', [
                      for (final file in savedFiles) paragraph(file),
                    ]),
                  section('What stays in the fork', [
                    paragraph(
                      'Tracks, water entries, moments, wake history, alarms, profile/settings and saved files. ECG attempt grouping and fork-only details do not appear in the official app.',
                    ),
                    paragraph(
                      'After the official file is saved, you can keep a second encrypted recovery file. It is selected by default. Credentials are excluded; re-enter keys and pair locally.',
                    ),
                  ]),
                  if (skipLines.isNotEmpty)
                    section('Skipped items', [
                      paragraph(
                        'These items are excluded from the official file. Originals remain in this fork. The file manifest lists each affected record.',
                      ),
                      for (final line in skipLines) paragraph(line),
                    ]),
                  section('Before importing in the official app', [
                    paragraph(
                      '1. Finish onboarding and enter your actual profile, units and sensor choices.',
                    ),
                    paragraph(
                      '2. Set recording retention to keep the history you intend to import. Re-enter your alarms.',
                    ),
                    paragraph(
                      '3. Mute historical insight notifications before import and reanalysis.',
                    ),
                    paragraph(
                      '4. Data > Import a file: select the official $officialTargetTag file. It may report “0 days imported” because scores were intentionally cleared.',
                    ),
                    paragraph(
                      '5. Data > Re-analyze everything. Keep the official app open, then verify your records and edits.',
                    ),
                  ]),
                  section('History limits', [
                    paragraph(
                      'Days whose exact recordings were removed cannot be rebuilt. Partial recordings do not guarantee a daily score.',
                    ),
                    paragraph(
                      'Some older workout details rebuild when opened. Details may stay blank where recordings were pruned.',
                    ),
                    paragraph(
                      'Stop the fork’s Bluetooth/background connection before pairing in the official app. Keep both apps and any recovery file until the import is checked.',
                    ),
                  ]),
                  if (phase != 'running' && phase != 'saved') ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'The official app has no personal history yet',
                      ),
                      value: fresh,
                      onChanged: onFreshChanged,
                    ),
                    if (!fresh)
                      paragraph(
                        'A populated official app needs its own backup and a separate merge plan. This pilot supports a fresh install only.',
                      ),
                    FilledButton(
                      onPressed: fresh ? onStart : null,
                      child: const Text('Choose folder and passphrase'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
