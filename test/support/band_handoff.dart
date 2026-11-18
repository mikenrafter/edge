// Queue and player unit tests supply authorization explicitly. Integration
// tests use AlertDispatcher instead, so its delivery-time permit is exercised.
import 'dart:async';

import 'package:fake_async/fake_async.dart' as fake;

export 'package:fake_async/fake_async.dart' show FakeAsync;
import 'package:openstrap_edge/haptics/band_queue.dart';

T withBandHandoff<T>(T Function() body) => runZoned(body,
    zoneValues: {kAlertHandoffKey: () async => true});

T fakeAsync<T>(T Function(fake.FakeAsync) body, {DateTime? initialTime}) =>
    fake.fakeAsync((async) => withBandHandoff(() => body(async)),
        initialTime: initialTime);
