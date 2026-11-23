// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import '../models/subscription.dart';

class DetectedConfigInput {
  final String protocol;
  final String payload;
  final bool isSubscription;

  const DetectedConfigInput({
    required this.protocol,
    required this.payload,
    required this.isSubscription,
  });
}

/// Detects a scanned/imported payload without trusting a manually selected
/// protocol. HTTP(S)/data: payloads are subscriptions; VPN links are detected
/// from a known scheme and from the optional caption used by LaLune backends
/// (`csqttr:csqtt://…`, `CSQTT 2.5.1: csqtt://…`).
DetectedConfigInput? detectConfigInput(String raw) {
  final input = raw.trim();
  if (input.isEmpty) return null;

  if (looksLikeSubscription(input)) {
    return DetectedConfigInput(
      protocol: 'LaLuneSUB',
      payload: stripSubscriptionPrefix(input),
      isSubscription: true,
    );
  }

  final lower = input.toLowerCase();
  const schemes = <String>['csqttr://', 'csqtt://', 'tots://'];
  int? schemeIndex;
  String? scheme;
  for (final candidate in schemes) {
    final index = lower.indexOf(candidate);
    if (index >= 0 && (schemeIndex == null || index < schemeIndex)) {
      schemeIndex = index;
      scheme = candidate;
    }
  }
  if (schemeIndex == null || scheme == null) return null;

  final label = input
      .substring(0, schemeIndex)
      .trim()
      .replaceFirst(RegExp(r':\s*$'), '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');
  final uri = input.substring(schemeIndex).split('\n').first.trim();

  String protocol;
  switch (label) {
    case 'csqttr':
    case 'csqttr 2.5.2':
      protocol = 'CSQTTR';
      break;
    case 'csqtt 2.5.1':
      protocol = 'CSQTT 2.5.1';
      break;
    case 'csqtt 2.1.9':
      protocol = 'CSQTT 2.1.9';
      break;
    case 'tots':
      protocol = 'ToTS';
      break;
    default:
      if (scheme == 'csqttr://') {
        protocol = 'CSQTTR';
      } else if (scheme == 'tots://') {
        protocol = 'ToTS';
      } else {
        // A plain connect?... link is the legacy 2.1.9 format. Opaque csqtt
        // payloads are handled by the 2.5.1 parser/core in the backends.
        final afterScheme = uri.substring('csqtt://'.length);
        protocol = afterScheme.toLowerCase().startsWith('connect?')
            ? 'CSQTT 2.1.9'
            : 'CSQTT 2.5.1';
      }
  }

  final payload = scheme == 'csqttr://'
      ? 'csqtt://${uri.substring('csqttr://'.length)}'
      : uri;
  return DetectedConfigInput(
    protocol: protocol,
    payload: payload,
    isSubscription: false,
  );
}
