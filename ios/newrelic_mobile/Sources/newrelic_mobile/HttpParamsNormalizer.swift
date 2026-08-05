/*
 * Copyright (c) 2022-present New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Coerces the `params` map from a `noticeHttpTransaction` call into scalar
/// attribute values.
///
/// Deliberately free of Flutter and NewRelic imports so it can be unit tested
/// without an iOS app build. Rationale for every rule, with worked values, lives
/// in `Tests/HttpParamsNormalizerTests/HttpParamsNormalizerTests.swift`.
enum HttpParamsNormalizer {
    /// Separator joining several distinct values into one attribute value.
    static let valueSeparator = ";"

    static func normalize(_ raw: Any?) -> [String: Any]? {
        guard let raw = raw as? [String: Any], !raw.isEmpty else { return nil }

        var merged: [String: (attribute: String, values: [String])] = [:]

        for key in raw.keys.sorted() {
            guard let value = raw[key] else { continue }

            let flattened: [String]
            switch value {
            case let string as String:
                flattened = [string]
            case let array as [Any]:
                flattened = array.map { String(describing: $0) }
            case is NSNull:
                flattened = []
            default:
                flattened = [String(describing: value)]
            }

            let incoming = flattened
                .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if incoming.isEmpty { continue }

            let headerKey = key.lowercased()
            if let existing = merged[headerKey] {
                merged[headerKey] = (existing.attribute, existing.values + incoming)
            } else {
                merged[headerKey] = (key, incoming)
            }
        }

        if merged.isEmpty { return nil }

        var normalized: [String: Any] = [:]
        for entry in merged.values {
            var seen = Set<String>()
            let distinct = entry.values.filter { seen.insert($0).inserted }
            normalized[entry.attribute] = distinct.joined(separator: valueSeparator)
        }
        return normalized
    }
}
