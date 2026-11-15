// One visual design check for the centred since row under the real guide.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'backup/backup_support.dart';
import 'support/live_guide_harness.dart';
import 'support/pilot_shots.dart';
import 'support/skeleton_fixture.dart' show skLoadAppFonts;
class _SinceRepo extends GuideFakeRepo {
  @override
  Future<List<String>> availableDays() async => [todayLabel(), dayLabelBefore(todayLabel(), 1)!];
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async => DateTime(2026, 11, 13, 21, 22);
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async { await skLoadAppFonts(); env = await BackupEnv.create('structural_guide_shot.db'); await LocalDb.instance; });
  tearDownAll(() => env.dispose());
  testWidgets('since row stays in the rings card while a guide is active', (t) async {
    final capture = GlobalKey();
    final app = await pumpLiveGuideApp(t, repo: _SinceRepo(),
      brightness: Brightness.dark, captureKey: capture);
    await app.runner.start(kGuideCatalogue.firstWhere((e) => e.guide.id == 'heart-rate-zones').guide, band: null);
    await settleLiveGuide(t);
    expect(app.runner.activeRun, isNotNull);
    expect(find.byKey(const ValueKey('home-since')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await takePilotShot(t, 'home-since-under-guide', captureKey: capture);
    app.runner.exit();
    await t.pump();
    await t.tap(find.bySemanticsLabel('Previous day'));
    await settleLiveGuide(t);
    await takePilotShot(t, 'home-past-day-with-tabs', captureKey: capture);
    final scroll = find.descendant(of: find.byType(HomeScreen), matching: find.byType(Scrollable)).first;
    for (var i = 0; i < 3; i++) {
      final position = t.state<ScrollableState>(scroll).position;
      position.jumpTo(position.maxScrollExtent);
      await t.pump();
    }
    await takePilotShot(t, 'home-last-content-with-pill', captureKey: capture);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });
}
