/*
 * Copyright (c) 2022-present New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

// Tests for HttpParamsNormalizer, which coerces the `params` map of a
// `noticeHttpTransaction` call into scalar attribute values before it reaches
// `NewRelic.noticeNetworkRequest(..., andParams:)`.
//
// WHY THIS CODE EXISTS AT ALL
// ---------------------------
// The iOS bridge used to hardcode `andParams: nil`, so every custom attribute the
// Dart layer collected was silently discarded at the native boundary. Android
// forwarded them. That is the second half of the iOS header-tracking fix begun in
// newrelic-flutter-agent#128, which made `getHTTPHeadersTrackingFor` return the
// tracked list instead of `[]` but left the captured values with nowhere to go.
//
// WHY IT NORMALISES RATHER THAN FORWARDING THE MAP AS-IS
// -----------------------------------------------------
// `noticeHttpTransaction(httpParams:)` is public API taking `Map<String, dynamic>`,
// so a caller that bypasses the Dart header capture — anything calling it directly
// — can hand over arrays, mixed types, or keys differing only in case. New Relic
// attribute values must be scalars, so each of those shapes has to collapse to one
// String. The rules deliberately match `trackedHeaderValues` /
// `mergedTrackedHeaderValue` in lib/src/tracked_headers.dart so that both entry
// points produce identical attributes for identical input; see
// test/tracked_headers_test.dart for the same cases on the Dart side.

import XCTest

@testable import newrelic_mobile

final class HttpParamsNormalizerTests: XCTestCase {

    /// Renders the result deterministically so assertions read as values.
    private func normalized(_ raw: Any?) -> String {
        guard let out = HttpParamsNormalizer.normalize(raw) else { return "nil" }
        return out.keys.sorted()
            .map { "\($0)=\(out[$0]!)" }
            .joined(separator: "  ")
    }

    // MARK: - nothing to attach

    func testNilInputYieldsNil() {
        // Upstream passed nil when there were no params; that must not become an
        // empty dictionary, which the agent would treat as "attributes present".
        XCTAssertEqual(normalized(nil), "nil")
    }

    func testEmptyMapYieldsNil() {
        XCTAssertEqual(normalized([String: Any]()), "nil")
    }

    func testMapThatEmptiesAfterFilteringYieldsNil() {
        // Every value dropped, so there is genuinely nothing to attach.
        XCTAssertEqual(normalized(["a": "", "b": NSNull()]), "nil")
    }

    func testWrongTopLevelTypeYieldsNil() {
        // Defensive: the method channel hands over `Any?`.
        XCTAssertEqual(normalized("not a map"), "nil")
    }

    // MARK: - the common case is a pass-through

    func testSingleStringValueIsUnchanged() {
        // What the Dart capture produces: one key, one already-merged String.
        // Normalisation must not disturb it.
        XCTAssertEqual(normalized(["x-request-id": "abc"]), "x-request-id=abc")
    }

    func testKeyCasingIsPreservedForASingleKey() {
        // The attribute name follows the key the caller chose. New Relic's own
        // defaults are upper-case (X-APOLLO-OPERATION-NAME), and lower-casing
        // them would rename existing attributes and break saved queries.
        XCTAssertEqual(normalized(["X-APOLLO-OPERATION-NAME": "Q"]),
                       "X-APOLLO-OPERATION-NAME=Q")
    }

    // MARK: - shape 1: array values

    func testArrayValueIsFlattenedAndJoined() {
        // An array would reach New Relic as an unusable non-scalar.
        XCTAssertEqual(normalized(["x-request-id": ["abc", "def"]]),
                       "x-request-id=abc;def")
    }

    func testArrayWithRepeatedValueIsDeduplicated() {
        // Matches the Set in mergedTrackedHeaderValue. Reporting 'abc;abc' is noise.
        XCTAssertEqual(normalized(["x-request-id": ["abc", "abc"]]),
                       "x-request-id=abc")
    }

    func testArrayOfNonStringsIsCoerced() {
        XCTAssertEqual(normalized(["retries": [1, 2]]), "retries=1;2")
    }

    func testEmptyArrayIsDropped() {
        XCTAssertEqual(normalized(["x-request-id": [String]()]), "nil")
    }

    // MARK: - shape 2: keys differing only in case

    func testCaseVariantKeysMergeIntoOneAttribute() {
        // HTTP header names are case-insensitive, so these are the SAME header
        // arriving as two dictionary keys. Left unmerged they would become two
        // New Relic columns for one header.
        XCTAssertEqual(normalized(["x-request-id": "abc", "X-Request-Id": "def"]),
                       "X-Request-Id=def;abc")
    }

    func testCaseVariantKeysWithTheSameValueCollapse() {
        // Reachable from the Dart path: if an app registers both casings via
        // addHTTPHeadersTrackingFor, header lookup is case-insensitive so both
        // iterations find the same value and write two keys. Without dedupe this
        // produced 'abc;abc'.
        XCTAssertEqual(normalized(["x-request-id": "abc", "X-Request-Id": "abc"]),
                       "X-Request-Id=abc")
    }

    func testThreeCaseVariantsStillProduceOneAttribute() {
        XCTAssertEqual(
            normalized(["x-req": "a", "X-Req": "b", "X-REQ": "c"]),
            "X-REQ=c;b;a")
    }

    func testMergedAttributeNameIsDeterministic() {
        // Keys are walked sorted, so the winning casing does not depend on
        // dictionary iteration order — which is not stable in Swift. Upper-case
        // sorts before lower-case in ASCII, hence 'X-Req' rather than 'x-req'.
        for _ in 0..<20 {
            XCTAssertEqual(normalized(["x-req": "a", "X-Req": "b"]), "X-Req=b;a")
        }
    }

    // MARK: - shape 3: mixed types for one header

    func testStringAndCaseVariantArrayMergeTogether() {
        XCTAssertEqual(
            normalized(["x-request-id": "abc", "X-Request-Id": ["def", "ghi"]]),
            "X-Request-Id=def;ghi;abc")
    }

    // MARK: - shape 4: values that are already comma-folded

    func testFoldedValueIsSplitBeforeMerging() {
        // A caller may hand over a raw header value that a sender already folded,
        // e.g. "abc, def" for a header sent twice (RFC 7230 §3.2.2). Splitting
        // here keeps behaviour identical to trackedHeaderValues on the Dart side.
        XCTAssertEqual(normalized(["x-request-id": "abc, def"]),
                       "x-request-id=abc;def")
    }

    func testFoldedRepeatCollapsesToOneValue() {
        // The case that motivated the split: without it this stayed the single
        // opaque string "abc, abc" and no dedupe could touch it.
        XCTAssertEqual(normalized(["x-request-id": "abc, abc"]),
                       "x-request-id=abc")
    }

    func testConsecutiveCommasDoNotProduceEmptyValues() {
        XCTAssertEqual(normalized(["x-request-id": "a,,b"]), "x-request-id=a;b")
    }

    func testWhitespaceAroundFoldedValuesIsTrimmed() {
        // Folding inserts ", " — comma AND space.
        XCTAssertEqual(normalized(["x-request-id": "  abc ,  def  "]),
                       "x-request-id=abc;def")
    }

    // MARK: - separator choice

    func testValuesAreJoinedWithSemicolonNotComma() {
        // Deliberate asymmetry: input is SPLIT on ',' because that is HTTP's
        // folding separator, but output is JOINED with ';' so our separator can
        // never be mistaken for a folded header value. That makes a ';' in a
        // reported attribute a reliable signal that two layers stamped genuinely
        // different values.
        let out = HttpParamsNormalizer.normalize(["x-request-id": ["abc", "def"]])
        let value = out?["x-request-id"] as? String
        XCTAssertEqual(value, "abc;def")
        XCTAssertFalse(value?.contains(",") ?? true)
        XCTAssertEqual(HttpParamsNormalizer.valueSeparator, ";")
    }

    func testSemicolonInsideASingleValueIsPreserved() {
        // Only commas split, so a Content-Type parameter survives intact. This is
        // also why ';' is safe as the output separator.
        XCTAssertEqual(normalized(["content-type": "text/html; charset=utf-8"]),
                       "content-type=text/html; charset=utf-8")
    }

    // MARK: - values that carry no information

    func testNSNullIsDropped() {
        // A JSON null crossing the method channel arrives as NSNull, and
        // String(describing:) would otherwise store the literal "<null>".
        XCTAssertEqual(normalized(["a": NSNull(), "c": "keep"]), "c=keep")
    }

    func testEmptyAndWhitespaceOnlyStringsAreDropped() {
        XCTAssertEqual(normalized(["a": "", "b": "   ", "c": "keep"]), "c=keep")
    }

    // MARK: - non-String scalars

    func testNonStringScalarIsCoerced() {
        // Attribute values must be scalars but need not be Strings on the Dart
        // side; coerce rather than drop, so information is not lost.
        XCTAssertEqual(normalized(["retries": 3]), "retries=3")
    }

    // MARK: - several headers at once

    func testMultipleDistinctHeadersEachBecomeTheirOwnAttribute() {
        XCTAssertEqual(
            normalized(["x-a": "1", "x-b": ["2", "3"]]),
            "x-a=1  x-b=2;3")
    }
}
