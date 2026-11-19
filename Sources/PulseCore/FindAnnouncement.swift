/// Chromium announces find-in-page progress ("Result 2 of 7", "3/7",
/// "Ergebnis 2 von 7"). Only the numbers matter: a current match above zero
/// means the page moved to one. The text is never kept.
public enum FindAnnouncement {
    public static func isMatch(_ text: String) -> Bool {
        var numbers: [Int] = []
        var current: Int?
        for scalar in text.unicodeScalars {
            if let digit = scalar.properties.numericType == .decimal ? scalar.properties.numericValue : nil {
                current = (current ?? 0) * 10 + Int(digit)
                if current! > 1_000_000 { return false }
            } else if let value = current {
                numbers.append(value)
                current = nil
            }
        }
        if let current { numbers.append(current) }
        // Exactly a position and a total, and the position is real.
        guard numbers.count == 2 else { return false }
        return numbers[0] >= 1 && numbers[0] <= numbers[1]
    }
}
