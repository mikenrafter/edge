// why: the chosen presentation must read structural pulse_ep_* rows without
// reviving the pilot schema or changing evidence/outbox state.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import '../backup/backup_support.dart';
import '../pulse_ep_support.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env=await BackupEnv.create('pilot-observations.db'));
  tearDownAll(() => env.dispose());
  setUp(() => env.wipe());
  // catches: reading the superseded pilot tables, decoding blobs for a list,
  // showing retracted revisions, or mutating delivery while displaying a row.
  test('summary read uses current active structural revision and preserves rows', () async {
    final db=await LocalDb.instance;
    await seedEpisode(db,id:'visible',startMs:1000,endMs:601000,startDay:'2026-11-17',endDay:'2026-11-18',state:'sent',evidence:false);
    await seedEpisode(db,id:'retracted',startMs:2000,endMs:602000,startDay:'2026-11-18',status:'retracted');
    final before=await db.query('pulse_ep_outbox');
    final rows=await LocalRepositoryImpl(getProfileMap:()=>{}).getPulseEpisodes();
    expect(rows.map((e)=>e.id),['visible']);
    expect(rows.single.deliveryState,'sent');
    expect(rows.single.evidenceStatus,'expired');
    expect(rows.single.occursOn('2026-11-18'),true);
    expect(rows.single.occursOn('2026-11-19'),false);
    expect(await db.query('pulse_ep_outbox'),before);
  });
}
