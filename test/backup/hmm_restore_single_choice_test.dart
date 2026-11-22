// Restore precedence for the two HMM staging keys (fix round 1, F2): either key
// in a backup lands in `sleep_hmm_stages`; the older key is never written; when
// a backup carries both, the upstream key's explicit value wins.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_hmm_choice_test.db'));
  tearDownAll(() async => env.dispose());

  Future<Map<String, Object>> restore(Map<String, Object> prefs) async {
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await setPrefs(prefs);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
    await LocalDb.importFromDbFile(path);
    return allPrefs();
  }

  test('the older key alone restores into sleep_hmm_stages', () async {
    final now = await restore({'compute.experimental_sleep_hmm': true});
    expect(now['sleep_hmm_stages'], true);
    expect(now.containsKey('compute.experimental_sleep_hmm'), isFalse);
  });

  test('both keys: the upstream key wins, whatever the older one says',
      () async {
    final now = await restore({
      'compute.experimental_sleep_hmm': true,
      'sleep_hmm_stages': false,
    });
    expect(now['sleep_hmm_stages'], false);
    expect(now.containsKey('compute.experimental_sleep_hmm'), isFalse);
  });

  test('the upstream key alone restores as it is', () async {
    final now = await restore({'sleep_hmm_stages': true});
    expect(now['sleep_hmm_stages'], true);
  });
}
