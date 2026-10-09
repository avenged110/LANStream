// MARK: - Formatting.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Type-checked replacements for the String(format:) calls the logs and DIDL used.
//
// String(format:) is a C-variadic API: nothing checks that each argument matches its
// conversion specifier, which is why Strict Memory Safety flags it. These produce the
// same text as "%.Nf", "%0Nd" and "%0Nllx" for the values this app formats, with the
// POSIX locale pinned so a log line never picks up a decimal comma.

import Foundation

extension Double {
    // Equivalent of String(format: "%.<digits>f", self): fixed fraction digits,
    // round-half-even, no grouping separators.
    func fixed(_ digits: Int) -> String {
        formatted(.number
            .precision(.fractionLength(digits))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }
}

extension BinaryInteger {
    // Equivalent of "%0<width>d" (radix 10) or "%0<width>llx" (radix 16) for
    // non-negative values: the digits left-padded with zeros to at least `width`.
    func zeroPadded(_ width: Int, radix: Int = 10) -> String {
        let digits = String(self, radix: radix)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
