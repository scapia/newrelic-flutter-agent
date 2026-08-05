/*
 * Copyright (c) 2022-present New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

import 'dart:io';

/// Separator used to join several distinct values into one attribute value.
///
/// Not a comma: see `test/tracked_headers_test.dart`.
const String trackedHeaderValueSeparator = ';';

/// Every discrete value of [name] in [headers], or an empty list when absent.
List<String> trackedHeaderValues(HttpHeaders headers, String name) {
  final values = headers[name];
  if (values == null) return const <String>[];
  return values
      .expand((value) => value.split(','))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

/// The single attribute value for [name], merged across both header bags, or
/// null when neither carries it.
String? mergedTrackedHeaderValue(
  HttpHeaders requestHeaders,
  HttpHeaders responseHeaders,
  String name,
) {
  final values = <String>{
    ...trackedHeaderValues(requestHeaders, name),
    ...trackedHeaderValues(responseHeaders, name),
  };
  if (values.isEmpty) return null;
  return values.join(trackedHeaderValueSeparator);
}

/// Attributes for every header in [trackedHeaders] that either bag carries.
///
/// Best-effort: returns whatever it managed to collect rather than throwing.
Map<String, String> trackedHeaderParams(
  Iterable<String> trackedHeaders,
  HttpHeaders requestHeaders,
  HttpHeaders responseHeaders,
) {
  final params = <String, String>{};
  try {
    for (final header in trackedHeaders) {
      final value =
          mergedTrackedHeaderValue(requestHeaders, responseHeaders, header);
      if (value == null) continue;
      params[header] = value;
    }
  } catch (_) {
    // Intentional: see 'never breaks the response it observes' in
    // test/tracked_headers_test.dart.
  }
  return params;
}
