/*
 * Copyright (c) 2022-present New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

import 'dart:async';
import 'newrelic_mobile.dart';

/// Centralized error handler for HTTP instrumentation
///
/// This class provides safe error handling for HTTP stream operations,
/// preventing crashes when streams are cancelled or closed unexpectedly.
class NewRelicHttpErrorHandler {
  /// Checks if an error is a stream closure error that should be silently handled
  static bool isStreamClosureError(dynamic error) {
    return error is StateError &&
           error.message.contains('Cannot add event after closing');
  }

  /// Safely executes a Future operation with automatic error handling
  ///
  /// Stream closure errors are silently handled to prevent app crashes.
  /// Other errors are recorded and rethrown.
  static Future<T> safeFuture<T>(
    Future<T> Function() operation, {
    T? fallbackValue,
    bool rethrowOnError = true,
  }) async {
    try {
      return await operation();
    } catch (error, stackTrace) {
      if (isStreamClosureError(error)) {
        // Stream was cancelled/closed, don't crash the app
        if (fallbackValue != null) {
          return fallbackValue;
        }
        rethrow;
      }
      // Record other errors for debugging
      NewrelicMobile.instance.recordError(error, stackTrace);
      if (rethrowOnError) {
        rethrow;
      }
      if (fallbackValue != null) {
        return fallbackValue;
      }
      rethrow;
    }
  }

  /// Safely executes an async generator with automatic error handling
  ///
  /// Stream closure errors cause graceful termination.
  /// Other errors are recorded and rethrown.
  static Stream<T> safeStream<T>(
    Stream<T> Function() streamGenerator,
  ) async* {
    try {
      await for (var item in streamGenerator()) {
        yield item;
      }
    } catch (error, stackTrace) {
      if (isStreamClosureError(error)) {
        // Stream was cancelled/closed, exit gracefully
        return;
      }
      // Record and rethrow other errors
      NewrelicMobile.instance.recordError(error, stackTrace);
      rethrow;
    }
  }

  /// Wraps a function execution with safe error handling
  ///
  /// Useful for operations that might throw but shouldn't crash the app.
  static void safeExecute(
    void Function() operation, {
    bool silenceStreamErrors = true,
  }) {
    try {
      operation();
    } catch (error, stackTrace) {
      if (silenceStreamErrors && isStreamClosureError(error)) {
        return;
      }
      NewrelicMobile.instance.recordError(error, stackTrace);
      rethrow;
    }
  }

  /// Safely records HTTP transaction, catching any errors
  static Future<void> safeRecordTransaction({
    required String url,
    required String method,
    required int statusCode,
    required int startTime,
    required int endTime,
    required int requestLength,
    required int responseLength,
    required dynamic traceData,
    dynamic httpParams,
    String? responseBody,
  }) async {
    try {
      await NewrelicMobile.instance.noticeHttpTransaction(
        url,
        method,
        statusCode,
        startTime,
        endTime,
        requestLength,
        responseLength,
        traceData,
        httpParams: httpParams,
        responseBody: responseBody ?? '',
      );
    } catch (error, stackTrace) {
      // If recording fails, log it but don't crash
      NewrelicMobile.instance.recordError(error, stackTrace);
    }
  }
}
