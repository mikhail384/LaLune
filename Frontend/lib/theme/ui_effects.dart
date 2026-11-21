// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps the app's glass palette while avoiding costly effects on older GPUs.
class UiEffects extends InheritedWidget {
  const UiEffects({
    super.key,
    required this.reduceEffects,
    required super.child,
  });

  final bool reduceEffects;

  static bool reduceEffectsOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiEffects>()?.reduceEffects ??
      false;

  static Future<bool> detectReducedEffects() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;

    try {
      return await const MethodChannel('com.lalune/native')
              .invokeMethod<bool>('preferReducedEffects') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  bool updateShouldNotify(UiEffects oldWidget) =>
      reduceEffects != oldWidget.reduceEffects;
}
