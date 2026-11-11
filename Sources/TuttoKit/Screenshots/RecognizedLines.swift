//
//  RecognizedLines.swift
//  Tutto
//
//  Text recognition reads a slashed zero (SF Mono and most code fonts draw 0 with a slash) as
//  "Ø" when the crop is tight: "with 0 failures" came back as "with Ø failures" in 4 tries of 4.
//  It's put back as 0 where it can only be a digit: next to a digit (1Ø0, 2.Ø5), or standing alone
//  in a line that has digits elsewhere. A word like "Øresund" is left alone.
//

import Foundation

public enum RecognizedLines {
    public static func fixingSlashedZeros(_ line: String) -> String {
        guard line.contains("Ø") else { return line }
        let chars = Array(line)
        let hasDigits = chars.contains { $0.isASCII && $0.isNumber }
        func digitish(_ index: Int) -> Bool {
            guard chars.indices.contains(index) else { return false }
            let c = chars[index]
            return (c.isASCII && c.isNumber) || c == "Ø"
        }
        func edge(_ index: Int) -> Bool {
            guard chars.indices.contains(index) else { return true }
            return !chars[index].isLetter
        }
        func separator(_ index: Int) -> Bool {
            chars.indices.contains(index) && (chars[index] == "." || chars[index] == ",")
        }
        var out = chars
        for i in chars.indices where chars[i] == "Ø" {
            let besideDigit = (i > 0 && chars[i - 1].isASCII && chars[i - 1].isNumber)
                || (i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber)
                || (separator(i - 1) && digitish(i - 2)) || (separator(i + 1) && digitish(i + 2))
                || (digitish(i - 1) && chars[i - 1] == "Ø" && hasDigits) || (digitish(i + 1) && chars[i + 1] == "Ø" && hasDigits)
            let alone = edge(i - 1) && edge(i + 1)
            if besideDigit || (alone && hasDigits) { out[i] = "0" }
        }
        return String(out)
    }
}
