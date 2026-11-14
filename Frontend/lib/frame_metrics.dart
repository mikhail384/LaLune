// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Local, opt-in frame measurements for device profiling. No profile data is sent.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

void startFrameMetrics() {
  if (!const bool.fromEnvironment('LALUNE_FRAME_METRICS')) return;
  final elapsed = <int>[];
  final build = <int>[];
  final raster = <int>[];
  SchedulerBinding.instance.addTimingsCallback((frames) {
    for (final frame in frames) {
      elapsed.add(frame.totalSpan.inMicroseconds);
      build.add(frame.buildDuration.inMicroseconds);
      raster.add(frame.rasterDuration.inMicroseconds);
    }
  });
  Timer.periodic(const Duration(seconds: 10), (_) {
    if (elapsed.isEmpty) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final hz = views.isEmpty ? 60.0 : views.first.display.refreshRate;
    final budget = 1000000 / (hz > 0 ? hz : 60);
    final sorted = List<int>.of(elapsed)..sort();
    int percentile(double p) => sorted[((sorted.length - 1) * p).ceil()];
    double mean(List<int> values) =>
        values.reduce((a, b) => a + b) / values.length / 1000;
    debugPrint('LALUNE_FRAME_METRICS ${jsonEncode({
      'frames': elapsed.length,
      'refreshHz': hz,
      'meanTotalMs': mean(elapsed),
      'p95TotalMs': percentile(.95) / 1000,
      'p99TotalMs': percentile(.99) / 1000,
      'meanBuildMs': mean(build),
      'meanRasterMs': mean(raster),
      'framesOverBudget': elapsed.where((value) => value > budget).length,
    })}');
    elapsed.clear();
    build.clear();
    raster.clear();
  });
}
