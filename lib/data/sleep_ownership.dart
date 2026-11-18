import 'sleep_editor.dart';
abstract final class SleepOwnership {
  static String dayOf(SleepBlockKind kind,int startSec,int endSec) => throw UnimplementedError();
  static Iterable<String> daysOf(int fromSec,int toSec) => throw UnimplementedError();
}
