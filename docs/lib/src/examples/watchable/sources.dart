import 'dart:async';

import 'package:zap/zap.dart';

final count = WritableWatchable(0);

// Create a watchable backed by a stream emitting the current time every second.
final time = Watchable<DateTime>.stream(Stream.multi((listener) {
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    listener.addSync(DateTime.now());
  });

  listener.onCancel = timer.cancel;
}), DateTime.now());