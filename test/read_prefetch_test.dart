// CLAIM read-prefetch: warming gives visible reads and derive priority, and
// navigation cancels the next step even when a previous read was in flight.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/read_prefetch.dart';

void main() {
  test('visible reads, derive and navigation prevent optional work', () async {
    final ticks = <Completer<void>>[];
    final prefetch = ReadPrefetch(
      idle: InlineAsyncWork(() {
        final c = Completer<void>();
        ticks.add(c);
        return c.future;
      }),
    );
    var read = 0;
    final visible = prefetch.visibleRead();
    final blocked = prefetch.warm('test', [
      InlineAsyncWork(() async {
        read++;
        return null;
      }),
    ], busy: () => false);
    ticks.removeAt(0).complete();
    await blocked;
    expect(read, 0);
    visible();
    final derive = prefetch.warm('test', [
      InlineAsyncWork(() async {
        read++;
        return null;
      }),
    ], busy: () => true);
    ticks.removeAt(0).complete();
    await derive;
    expect(read, 0);
    final current = Completer<Object?>();
    final warming = prefetch.warm('test', [
      InlineAsyncWork(() {
        read++;
        return current.future;
      }),
      InlineAsyncWork(() async {
        read++;
        return null;
      }),
    ], busy: () => false);
    ticks.removeAt(0).complete();
    await Future<void>.value();
    expect(read, 1);
    prefetch.cancel();
    current.complete();
    await Future<void>.value();
    ticks.removeAt(0).complete();
    await warming;
    expect(read, 1, reason: 'the read after navigation must never issue');
  });
}
