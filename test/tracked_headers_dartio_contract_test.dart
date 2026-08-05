/*
 * Copyright (c) 2022-present New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

// Pins the dart:io behaviours that lib/src/tracked_headers.dart is built on.
//
// tracked_headers_test.dart uses a FakeHttpHeaders because `HttpHeaders` cannot
// be constructed — dart:io's implementation class is private. That fake is only
// trustworthy if it models the real thing, so these tests drive a real loopback
// HttpServer and assert the five behaviours the design depends on.
//
// If a future Dart SDK changes any of them, these fail and point at the fake
// rather than leaving the unit tests quietly testing fiction.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:newrelic_mobile/src/tracked_headers.dart';

const kHeader = 'x-request-id';

void main() {
  late HttpServer server;
  late HttpClient client;
  late String base;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) {
      // Echo each value as its own response header line.
      final echo = request.uri.queryParameters['echo'];
      if (echo != null) {
        for (final value in echo.split('|').where((s) => s.isNotEmpty)) {
          request.response.headers.add(kHeader, value);
        }
      }
      final contentType = request.uri.queryParameters['ct'];
      if (contentType != null) {
        request.response.headers.set('content-type', contentType);
      }
      request.response.statusCode = 200;
      request.response.write('{}');
      request.response.close();
    });
    client = HttpClient();
    base = 'http://${server.address.host}:${server.port}';
  });

  tearDownAll(() async {
    client.close();
    await server.close(force: true);
  });

  /// Performs one round trip, returning the request and response header bags —
  /// exactly the two objects _wrapResponse is handed.
  Future<List<HttpHeaders>> roundTrip({
    List<String> requestValues = const [],
    List<String> responseValues = const [],
    String? requestContentType,
    String? responseContentType,
  }) async {
    final uri = Uri.parse('$base/').replace(queryParameters: {
      if (responseValues.isNotEmpty) 'echo': responseValues.join('|'),
      if (responseContentType != null) 'ct': responseContentType,
    });
    final request = await client.postUrl(uri);
    for (final value in requestValues) {
      request.headers.add(kHeader, value);
    }
    if (requestContentType != null) {
      request.headers.set('Content-Type', requestContentType);
    }
    final response = await request.close();
    await response.transform(utf8.decoder).drain();
    return <HttpHeaders>[request.headers, response.headers];
  }

  group('dart:io contract', () {
    test('a request bag keeps one entry per add — NOT folded', () {
      // What FakeHttpHeaders.addEntry models.
      final request = HttpClient();
      addTearDown(request.close);
      return request.postUrl(Uri.parse('$base/')).then((r) {
        r.headers.add(kHeader, 'a');
        r.headers.add(kHeader, 'b');
        expect(r.headers[kHeader], ['a', 'b']);
        return r.close().then((res) => res.drain());
      });
    });

    test('a sender FOLDS repeats into one comma-joined value on the wire',
        () async {
      // What FakeHttpHeaders.addFolded models, and the discovery that forced the
      // `.split(',')` in trackedHeaderValues. The server added two header lines;
      // dart:io joined them with ', ' when writing, so the client sees ONE value.
      //
      // Note the length assertion: ['a, b'] and ['a', 'b'] both render as
      // "[a, b]" under toString(), so element count is what actually proves it.
      final bags = await roundTrip(responseValues: ['resA', 'resB']);
      expect(bags[1][kHeader], hasLength(1));
      expect(bags[1][kHeader]!.single, 'resA, resB');

      // And the split undoes it, which is the whole point.
      expect(trackedHeaderValues(bags[1], kHeader), ['resA', 'resB']);
    });

    test('a folded repeat of ONE value is why dedupe needs the split first',
        () async {
      final bags = await roundTrip(responseValues: ['abc', 'abc']);
      expect(bags[1][kHeader]!.single, 'abc, abc',
          reason: 'arrives as a single opaque string');
      expect(mergedTrackedHeaderValue(bags[0], bags[1], kHeader), 'abc',
          reason: 'split then Set collapses it');
    });

    test('header names are lower-cased on write and lookup ignores case',
        () async {
      // Why trackedHeaderValues needs no case handling of its own, and why the
      // casing passed to addHTTPHeadersTrackingFor does not matter.
      final request = await client.postUrl(Uri.parse('$base/'));
      request.headers.add('Header-1', 'a');
      request.headers.add('Header-1', 'b');
      request.headers.add('header-1', 'a');

      expect(request.headers['Header-1'], ['a', 'b', 'a']);
      expect(request.headers['header-1'], ['a', 'b', 'a']);
      expect(request.headers['HEADER-1'], ['a', 'b', 'a']);

      final storedNames = <String>[];
      request.headers.forEach((name, _) {
        if (name.toLowerCase().startsWith('header-1')) storedNames.add(name);
      });
      expect(storedNames, ['header-1'],
          reason: 'one key, not two case-variants');

      expect(mergedTrackedHeaderValue(request.headers, request.headers, 'Header-1'),
          'a;b');
      await (await request.close()).drain();
    });

    test('HttpHeaders.value() throws on a repeat but operator[] does not',
        () async {
      // The bug that shipped. `.value()` was safe while only request headers were
      // read because the app controls those; on a response it fails the HTTP call.
      final bags = await roundTrip(responseValues: ['abc', 'def']);
      final request = await client.postUrl(Uri.parse('$base/'));
      request.headers.add(kHeader, 'abc');
      request.headers.add(kHeader, 'def');

      expect(() => request.headers.value(kHeader), throwsA(isA<HttpException>()));
      expect(request.headers[kHeader], ['abc', 'def']);
      expect(() => trackedHeaderValues(request.headers, kHeader), returnsNormally);
      expect(() => trackedHeaderValues(bags[1], kHeader), returnsNormally);
      await (await request.close()).drain();
    });

    test('special headers overwrite instead of appending', () async {
      // content-type, content-length, host, date, expires, if-modified-since and
      // transfer-encoding are stored via dedicated fields, so they can never be
      // multi-valued — meaning .value() could never have thrown for them, and the
      // crash was confined to generic headers like x-sc-request-id.
      final request = await client.postUrl(Uri.parse('$base/'));
      request.headers.add('content-type', 'application/json');
      request.headers.add('content-type', 'text/html');
      expect(request.headers['content-type'], ['text/html']);
      await (await request.close()).drain();
    });
  });

  group('end-to-end over a real socket', () {
    test('same value on both sides collapses', () async {
      final bags = await roundTrip(requestValues: ['abc'], responseValues: ['abc']);
      expect(mergedTrackedHeaderValue(bags[0], bags[1], kHeader), 'abc');
    });

    test('different values on each side are joined with ";"', () async {
      final bags = await roundTrip(requestValues: ['abc'], responseValues: ['def']);
      expect(mergedTrackedHeaderValue(bags[0], bags[1], kHeader), 'abc;def');
    });

    test('response-only header is captured', () async {
      final bags = await roundTrip(responseValues: ['abc']);
      expect(trackedHeaderParams([kHeader], bags[0], bags[1]),
          {kHeader: 'abc'});
    });

    test('absent on both sides writes no attribute', () async {
      final bags = await roundTrip();
      expect(trackedHeaderParams([kHeader], bags[0], bags[1]), isEmpty);
    });

    test('Content-Type identical on both sides collapses', () async {
      final bags = await roundTrip(
          requestContentType: 'application/json',
          responseContentType: 'application/json');
      expect(mergedTrackedHeaderValue(bags[0], bags[1], 'content-type'),
          'application/json');
    });

    test('Content-Type differing per side keeps both', () async {
      final bags = await roundTrip(
          requestContentType: 'application/json',
          responseContentType: 'text/html');
      expect(mergedTrackedHeaderValue(bags[0], bags[1], 'content-type'),
          'application/json;text/html');
    });

    test('a semicolon parameter survives the comma split', () async {
      final bags = await roundTrip(responseContentType: 'text/html; charset=utf-8');
      expect(trackedHeaderValues(bags[1], 'content-type'),
          ['text/html; charset=utf-8']);
    });
  });
}
