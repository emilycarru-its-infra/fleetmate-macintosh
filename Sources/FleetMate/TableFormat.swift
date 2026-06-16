import Foundation

extension String {
    /// Left-justify into a fixed-width column, truncating if longer.
    ///
    /// Safe replacement for `String(format: "%-Ns", swiftString)`, which treats
    /// a Swift `String` as a C `char *` and crashes in `strlen`. Use as
    /// `value.col(15)` and join columns with a space.
    func col(_ width: Int) -> String {
        let truncated = count > width ? String(prefix(width)) : self
        return truncated + String(repeating: " ", count: max(0, width - truncated.count))
    }
}

extension Int {
    /// Left-justify an integer into a fixed-width column.
    func col(_ width: Int) -> String { String(self).col(width) }
}
