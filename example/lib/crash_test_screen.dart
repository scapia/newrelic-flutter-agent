/*
 * Copyright (c) 2022-present New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Test screen for reproducing HTTP instrumentation crash scenarios
///
/// This screen tests the fix for the "Bad state: Cannot add event after closing" crash
/// that occurred when HTTP requests were cancelled due to navigation, network changes,
/// or app backgrounding.
class CrashTestScreen extends StatefulWidget {
  const CrashTestScreen({Key? key}) : super(key: key);

  @override
  State<CrashTestScreen> createState() => _CrashTestScreenState();
}

class _CrashTestScreenState extends State<CrashTestScreen> {
  final List<String> _logs = [];
  CancelToken? _dioCancelToken;
  HttpClient? _httpClient;
  bool _isLoading = false;

  void _addLog(String message) {
    setState(() {
      _logs.insert(0, '${DateTime.now().toIso8601String()}: $message');
      if (_logs.length > 20) {
        _logs.removeLast();
      }
    });
    if (kDebugMode) {
      print(message);
    }
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  /// Test 1: Make a long HTTP request and navigate away
  /// This cancels the request mid-flight
  Future<void> _testNavigateAway() async {
    _addLog('Starting long HTTP request...');
    setState(() => _isLoading = true);

    // Start a request with a 15 second delay
    try {
      final response = await http.get(
        Uri.parse('https://postman-echo.com/delay/15'),
      ).timeout(const Duration(seconds: 20));

      _addLog('Request completed: ${response.statusCode}');
    } catch (e) {
      _addLog('Request cancelled/failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Test 2: Make multiple concurrent requests and navigate away
  Future<void> _testMultipleRequestsAndNavigate() async {
    _addLog('Starting multiple HTTP requests...');
    setState(() => _isLoading = true);

    try {
      final futures = [
        http.get(Uri.parse('https://postman-echo.com/delay/10')),
        http.get(Uri.parse('https://jsonplaceholder.typicode.com/posts')),
        http.get(Uri.parse('https://api.github.com')),
      ];

      await Future.wait(futures).timeout(const Duration(seconds: 15));
      _addLog('All requests completed');
    } catch (e) {
      _addLog('Requests cancelled/failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Test 3: HttpClient with request cancellation
  Future<void> _testHttpClientCancellation() async {
    _addLog('Starting HttpClient request...');
    setState(() => _isLoading = true);

    try {
      _httpClient = HttpClient();
      final request = await _httpClient!.getUrl(
        Uri.parse('https://postman-echo.com/delay/15'),
      );

      final response = await request.close();

      await response.transform(const Utf8Decoder()).listen((contents) {
        _addLog('Received data: ${contents.substring(0, 50)}...');
      }).asFuture();

      _addLog('HttpClient request completed');
    } catch (e) {
      _addLog('HttpClient request failed: $e');
    } finally {
      _httpClient?.close();
      _httpClient = null;
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Test 4: Dio with explicit cancellation
  Future<void> _testDioCancellation() async {
    _addLog('Starting Dio request with cancel token...');
    setState(() => _isLoading = true);

    _dioCancelToken = CancelToken();

    try {
      final dio = Dio();
      final response = await dio.get(
        'https://postman-echo.com/delay/15',
        cancelToken: _dioCancelToken,
      );

      _addLog('Dio request completed: ${response.statusCode}');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _addLog('Dio request was cancelled');
      } else {
        _addLog('Dio request failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      _dioCancelToken = null;
    }
  }

  /// Cancel ongoing Dio request
  void _cancelDioRequest() {
    if (_dioCancelToken != null && !_dioCancelToken!.isCancelled) {
      _dioCancelToken!.cancel('User cancelled');
      _addLog('Cancelled Dio request');
    }
  }

  /// Test 5: Rapid successive requests
  Future<void> _testRapidRequests() async {
    _addLog('Starting rapid successive requests...');
    setState(() => _isLoading = true);

    try {
      for (int i = 0; i < 5; i++) {
        _addLog('Request $i starting...');
        await http.get(Uri.parse('https://jsonplaceholder.typicode.com/posts/$i'));
        _addLog('Request $i completed');

        // Small delay between requests
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _addLog('All rapid requests completed');
    } catch (e) {
      _addLog('Rapid requests failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _httpClient?.close(force: true);
    _cancelDioRequest();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crash Test Screen'),
        backgroundColor: Colors.red[700],
      ),
      body: Column(
        children: [
          // Instructions Card
          Card(
            margin: const EdgeInsets.all(8),
            color: Colors.blue[50],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Test Scenarios:',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '1. Tap a test button to start HTTP request(s)\n'
                    '2. Navigate away using back button or navigation\n'
                    '3. Toggle airplane mode during request\n'
                    '4. Switch WiFi/Cellular during request\n'
                    '5. Background app during request\n'
                    '6. Use "Cancel Dio" button to cancel explicitly',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),

          // Test Buttons
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : () async {
                    await _testNavigateAway();
                  },
                  icon: const Icon(Icons.directions_run),
                  label: const Text('Test 1: Long Request (15s) - Then Navigate Away'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 8),

                ElevatedButton.icon(
                  onPressed: _isLoading ? null : () async {
                    await _testMultipleRequestsAndNavigate();
                  },
                  icon: const Icon(Icons.cloud_sync),
                  label: const Text('Test 2: Multiple Concurrent Requests'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 8),

                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _testHttpClientCancellation,
                  icon: const Icon(Icons.http),
                  label: const Text('Test 3: HttpClient Request'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 8),

                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _testDioCancellation,
                  icon: const Icon(Icons.speed),
                  label: const Text('Test 4: Dio with Cancel Token'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 8),

                ElevatedButton.icon(
                  onPressed: _dioCancelToken != null && !_dioCancelToken!.isCancelled
                      ? _cancelDioRequest
                      : null,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel Dio Request'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 8),

                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _testRapidRequests,
                  icon: const Icon(Icons.flash_on),
                  label: const Text('Test 5: Rapid Successive Requests'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 16),

                ElevatedButton.icon(
                  onPressed: _clearLogs,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear Logs'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey,
                    padding: const EdgeInsets.all(8),
                  ),
                ),
              ],
            ),
          ),

          // Loading Indicator
          if (_isLoading)
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.yellow[100],
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Text('Request in progress... Try navigating away now!'),
                ],
              ),
            ),

          // Log Display
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: Colors.black87,
              border: Border.all(color: Colors.grey),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.grey[800],
                  child: const Row(
                    children: [
                      Icon(Icons.terminal, color: Colors.white, size: 16),
                      SizedBox(width: 8),
                      Text(
                        'Event Log',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          _logs[index],
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}