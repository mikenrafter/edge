import 'package:flutter_test/flutter_test.dart';
import 'pref_key_scanner.dart';

void main() {
  // why: file-wide `key` lookup merged unrelated stores and mis-typed flags.
  test('class keys remain scoped and enum fields enumerate their own values', () {
    const source = '''
class Alarms { static const key = 'alarms'; void read() { prefs.getString(key); } }
class Snooze { static const key = 'snooze'; void read() { prefs.getString(key); } }
enum Flag {
  first('flag.first'), second('flag.second', byDefault: true);
  const Flag(this.key, {this.byDefault = false});
  final bool byDefault;
  final String key;
  bool get enabled => prefs.getBool(key);
}
const alias = Alarms.key;
''';
    final scanner = PrefKeyScanner({'fixture.dart': source});
    expect(scanner.resolve('fixture.dart', 'key', source.indexOf('getString')), {'alarms'});
    expect(scanner.resolve('fixture.dart', 'key', source.lastIndexOf('getString')), {'snooze'});
    expect(scanner.resolve('fixture.dart', 'key', source.indexOf('getBool')), {'flag.first', 'flag.second'});
    expect(scanner.resolve('fixture.dart', 'Flag.first.key', 0), {'flag.first'});
    expect(scanner.resolve('fixture.dart', 'Flag.second.key', 0), {'flag.second'});
    expect(scanner.resolve('fixture.dart', 'alias', 0), {'alarms'});
    expect(scanner.resolve('fixture.dart', 'key', source.length), isEmpty);
    expect(scanner.resolve('fixture.dart', 'Unknown.key', 0), isEmpty);
  });
}
