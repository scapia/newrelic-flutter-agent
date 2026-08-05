/*
 * Copyright (c) 2022-present New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

// Tests for lib/src/tracked_headers.dart — the capture of `addHTTPHeadersTrackingFor`
// headers into HttpTransaction attributes.
//
// WHY THIS CODE EXISTS AT ALL
// ---------------------------
// The capture used to read request headers only:
//
//     if (request.headers.value(header) != null) {
//       params.putIfAbsent(header, () => request.headers.value(header)!);
//     }
//
// Two problems, both covered below:
//
//   1. A header the SERVER sets and the client never sends — a backend request
//      id, a rate-limit counter, a cache status — could not be tracked at all.
//      Reading `response.headers` is the whole point of the feature.
//
//   2. `HttpHeaders.value()` THROWS `HttpException` when a header appears more
//      than once. That was unreachable while only request headers were read,
//      because the app controls those. Response headers are set by the server
//      and whatever proxies sit in front of it, and duplicates happen. Worse,
//      this runs inside the response chain, so the throw propagated into the
//      response Future and failed the HTTP CALL — not just the attribute.
//      Observability must never break the request it observes.
//
// See tracked_headers_dartio_contract_test.dart for tests that pin the dart:io
// behaviours these decisions rest on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:newrelic_mobile/src/tracked_headers.dart';

/// Minimal stand-in for a header bag, so tests can build exact shapes without a
/// live socket. Storage rules match dart:io and are pinned by the contract test:
/// names are lower-cased on write and lookup is case-insensitive.
class FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _store = <String, List<String>>{};

  /// One entry per call — the shape `HttpClientRequest.headers.add` produces,
  /// and the shape the parser produces when a server sends a header on separate
  /// lines.
  void addEntry(String name, String value) =>
      (_store[name.toLowerCase()] ??= <String>[]).add(value);

  /// A single already-folded entry — the shape that arrives when the sender
  /// combines repeated header lines into one comma-separated value.
  void addFolded(String name, List<String> values) =>
      _store[name.toLowerCase()] = <String>[values.join(', ')];

  @override
  List<String>? operator [](String name) => _store[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed by tests');
}

/// A bag that blows up on read, to prove the capture is best-effort.
class ThrowingHttpHeaders implements HttpHeaders {
  @override
  List<String>? operator [](String name) =>
      throw const FileSystemException('header bag exploded');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

FakeHttpHeaders headers({
  List<String> entries = const [],
  List<String>? folded,
  String name = 'x-request-id',
}) {
  final h = FakeHttpHeaders();
  for (final v in entries) {
    h.addEntry(name, v);
  }
  if (folded != null) h.addFolded(name, folded);
  return h;
}

const kHeader = 'x-request-id';
final empty = FakeHttpHeaders();

void main() {
  group('trackedHeaderValues — reading one bag', () {
    test('absent header yields an empty list, never null', () {
      // The caller merges lists, so "absent" has to be spreadable.
      expect(trackedHeaderValues(empty, kHeader), isEmpty);
    });

    test('single value is returned as-is', () {
      expect(trackedHeaderValues(headers(entries: ['abc']), kHeader), ['abc']);
    });

    test('separate entries are all returned', () {
      // Shape 1: two `.add` calls, or a server sending two header lines.
      expect(trackedHeaderValues(headers(entries: ['abc', 'def']), kHeader),
          ['abc', 'def']);
    });

    test('a folded value is split back into its parts', () {
      // Shape 2, and the reason `.split(',')` exists. RFC 7230 §3.2.2 lets a
      // sender combine repeated field lines into one comma-separated value, and
      // dart:io does exactly that when writing any header except set-cookie.
      // Without the split this arrives as ONE opaque string, and no amount of
      // de-duplication downstream can collapse it.
      expect(trackedHeaderValues(headers(folded: ['abc', 'def']), kHeader),
          ['abc', 'def']);
    });

    test('a folded REPEAT is split, which is what makes dedupe possible', () {
      // The real-world case: a backend stamps x-sc-request-id twice with the
      // same value. Pre-split this was the single string 'abc, abc', so the Set
      // in mergedTrackedHeaderValue saw one element and produced 'abc,abc'.
      expect(trackedHeaderValues(headers(folded: ['abc', 'abc']), kHeader),
          ['abc', 'abc']);
    });

    test('whitespace around values is trimmed', () {
      // Folding inserts ', ' — comma AND space — so the space must go or every
      // second value would carry a leading blank.
      expect(trackedHeaderValues(headers(entries: ['  abc  ']), kHeader), ['abc']);
    });

    test('empty and whitespace-only values are dropped', () {
      expect(trackedHeaderValues(headers(entries: ['', '   ', 'abc']), kHeader),
          ['abc']);
    });

    test('consecutive commas do not produce empty values', () {
      expect(trackedHeaderValues(headers(entries: ['a,,b']), kHeader), ['a', 'b']);
    });

    test('lookup is case-insensitive, so registered casing does not matter', () {
      final h = headers(entries: ['abc'], name: 'X-Request-Id');
      expect(trackedHeaderValues(h, 'x-request-id'), ['abc']);
      expect(trackedHeaderValues(h, 'X-REQUEST-ID'), ['abc']);
    });

    test('a semicolon inside a single value is preserved', () {
      // Only commas split. `Content-Type: text/html; charset=utf-8` is ONE value
      // with a parameter, so splitting on ';' would tear it apart — which is
      // also why ';' is safe to use as the OUTPUT separator.
      expect(
        trackedHeaderValues(
            headers(entries: ['text/html; charset=utf-8'], name: 'content-type'),
            'content-type'),
        ['text/html; charset=utf-8'],
      );
    });

    test('a genuine comma-list header splits — intended', () {
      // Accept really is a comma-separated list, so this is correct behaviour.
      expect(
        trackedHeaderValues(
            headers(entries: ['text/html, application/json'], name: 'accept'),
            'accept'),
        ['text/html', 'application/json'],
      );
    });

    test('KNOWN TRADE-OFF: a comma inside one value is split', () {
      // Accepted cost of unfolding. An HTTP-date carries a comma, so tracking a
      // date-like header would mangle it. Tracked headers are ids and operation
      // names in practice, and without the split de-duplication cannot work at
      // all — so this is the deliberate choice, pinned here so a future change
      // is a decision rather than an accident.
      expect(
        trackedHeaderValues(
            headers(entries: ['Wed, 05 Aug 2026 12:00:00 GMT'], name: 'x-when'),
            'x-when'),
        ['Wed', '05 Aug 2026 12:00:00 GMT'],
      );
    });

    test('never throws on a repeated header, unlike HttpHeaders.value()', () {
      // The regression that shipped a fatal crash. `.value()` throws
      // HttpException("More than one value for header ...") here.
      expect(() => trackedHeaderValues(headers(entries: ['abc', 'def']), kHeader),
          returnsNormally);
    });
  });

  group('mergedTrackedHeaderValue — merging request and response', () {
    test('null when neither bag carries the header, so no attribute is written',
        () {
      expect(mergedTrackedHeaderValue(empty, empty, kHeader), isNull);
    });

    test('request-only value', () {
      expect(mergedTrackedHeaderValue(headers(entries: ['abc']), empty, kHeader),
          'abc');
    });

    test('response-only value — the case upstream could not capture', () {
      expect(mergedTrackedHeaderValue(empty, headers(entries: ['abc']), kHeader),
          'abc');
    });

    test('the same value on both sides collapses to one', () {
      // A Set is used rather than a List precisely for this. Reporting
      // 'abc;abc' would be noise.
      expect(
        mergedTrackedHeaderValue(
            headers(entries: ['abc']), headers(entries: ['abc']), kHeader),
        'abc',
      );
    });

    test('different values on each side are both kept', () {
      expect(
        mergedTrackedHeaderValue(
            headers(entries: ['abc']), headers(entries: ['def']), kHeader),
        'abc;def',
      );
    });

    test('a response repeating one value collapses to that value', () {
      expect(
        mergedTrackedHeaderValue(empty, headers(folded: ['abc', 'abc']), kHeader),
        'abc',
      );
    });

    test('a response with two distinct values keeps both', () {
      expect(
        mergedTrackedHeaderValue(empty, headers(folded: ['abc', 'def']), kHeader),
        'abc;def',
      );
    });

    test('first-seen order is preserved while duplicates drop out', () {
      // A Set literal is a LinkedHashSet, so insertion order survives: request
      // values first, then response values.
      expect(
        mergedTrackedHeaderValue(headers(entries: ['abc']),
            headers(folded: ['def', 'abc', 'ghi']), kHeader),
        'abc;def;ghi',
      );
    });

    test('joins with ";" and never with ","', () {
      // Deliberate asymmetry: input is SPLIT on ',' because that is HTTP's
      // folding separator, but output is JOINED with ';' so our separator can
      // never be mistaken for a folded header value. That makes a ';' in a
      // reported attribute a reliable signal that two layers stamped genuinely
      // different values.
      final merged = mergedTrackedHeaderValue(
          headers(entries: ['abc']), headers(entries: ['def']), kHeader);
      expect(merged, contains(';'));
      expect(merged, isNot(contains(',')));
    });

    test('Content-Type identical on both sides collapses', () {
      expect(
        mergedTrackedHeaderValue(
          headers(entries: ['application/json'], name: 'content-type'),
          headers(entries: ['application/json'], name: 'content-type'),
          'content-type',
        ),
        'application/json',
      );
    });

    test('Content-Type differing per side keeps both', () {
      expect(
        mergedTrackedHeaderValue(
          headers(entries: ['application/json'], name: 'content-type'),
          headers(entries: ['text/html'], name: 'content-type'),
          'content-type',
        ),
        'application/json;text/html',
      );
    });

    test('case-variant names are one header, so their values merge', () {
      // dart:io lower-cases on write, so 'Header-1' and 'header-1' are the same
      // key holding ['a', 'b', 'a'] — which dedupes to 'a;b'. This is also why
      // the Dart side needs no case-merging logic of its own.
      final h = FakeHttpHeaders()
        ..addEntry('Header-1', 'a')
        ..addEntry('Header-1', 'b')
        ..addEntry('header-1', 'a');
      expect(mergedTrackedHeaderValue(h, empty, 'Header-1'), 'a;b');
    });
  });

  group('trackedHeaderParams — building the attribute map', () {
    test('one entry per tracked header that either bag carries', () {
      final request = FakeHttpHeaders()..addEntry('x-a', '1');
      final response = FakeHttpHeaders()..addEntry('x-b', '2');
      expect(
        trackedHeaderParams(['x-a', 'x-b'], request, response),
        {'x-a': '1', 'x-b': '2'},
      );
    });

    test('headers absent from both bags are omitted entirely', () {
      // Not written as an empty string: an attribute that means "we looked and
      // found nothing" would be indistinguishable from a real empty value.
      expect(trackedHeaderParams(['x-missing'], empty, empty), isEmpty);
    });

    test('the attribute key is the tracked header name, untransformed', () {
      // No renaming happens here. Which header to track is the app's decision
      // via addHTTPHeadersTrackingFor, and the attribute name follows it, so
      // this stays a general-purpose plugin rather than encoding one product's
      // naming preference.
      final response = FakeHttpHeaders()..addEntry('x-sc-request-id', 'abc');
      expect(trackedHeaderParams(['x-sc-request-id'], empty, response),
          {'x-sc-request-id': 'abc'});
    });

    test('an empty tracked list yields no attributes', () {
      expect(trackedHeaderParams(const [], empty, empty), isEmpty);
    });

    test('never breaks the response it observes: a throwing bag is swallowed',
        () {
      // The guard that exists because the first version of this feature shipped
      // a crash which failed real API calls. Losing an attribute is acceptable;
      // failing the user's request is not.
      expect(
        () => trackedHeaderParams(['x-a'], ThrowingHttpHeaders(), empty),
        returnsNormally,
      );
      expect(trackedHeaderParams(['x-a'], ThrowingHttpHeaders(), empty), isEmpty);
    });

    test('a mid-list failure keeps the attributes gathered before it', () {
      // Best-effort, not all-or-nothing.
      final ok = FakeHttpHeaders()..addEntry('x-a', '1');
      var calls = 0;
      final flaky = _FlakyOnSecondLookup(ok, () => ++calls);
      expect(trackedHeaderParams(['x-a', 'x-b'], flaky, empty), {'x-a': '1'});
    });
  });
}

/// Succeeds once, then throws — used to show partial results are kept.
class _FlakyOnSecondLookup implements HttpHeaders {
  final FakeHttpHeaders _delegate;
  final int Function() _tick;

  _FlakyOnSecondLookup(this._delegate, this._tick);

  @override
  List<String>? operator [](String name) {
    if (_tick() > 1) throw const FileSystemException('second lookup exploded');
    return _delegate[name];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
