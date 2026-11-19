/// A Force Touch trackpad's firmware click, in the form the HID report that
/// sets it carries it. Pulse only ever changes the single-pulse form,
/// `[1, amplitude, duration]`; anything else is left exactly as it is.
public enum ClickWaveform {
    /// The same pulse at zero amplitude, or nil for a form Pulse doesn't know.
    public static func silenced(_ report: [UInt8]) -> [UInt8]? {
        guard isSinglePulse(report) else { return nil }
        return [report[0], 0, report[2]]
    }

    public static func isSilent(_ report: [UInt8]) -> Bool {
        isSinglePulse(report) && report[1] == 0
    }

    private static func isSinglePulse(_ report: [UInt8]) -> Bool {
        report.count == 3 && report[0] == 1
    }
}
