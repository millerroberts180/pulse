import AppKit

if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
    exit(0)
}
if CommandLine.arguments.contains("--probe") {
    Diagnostics.probe()
    exit(0)
}
#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--dump-sounds"), index + 1 < CommandLine.arguments.count {
    Diagnostics.dumpSounds(to: CommandLine.arguments[index + 1])
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--make-icon"), index + 1 < CommandLine.arguments.count {
    exit(PulseLogo.writeIcon(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}
if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}
if let index = CommandLine.arguments.firstIndex(of: "--snapshot-ui"), index + 1 < CommandLine.arguments.count {
    UISnapshots.render(to: CommandLine.arguments[index + 1])
    exit(0)
}
#endif

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory) // Menu bar only, no Dock icon.
application.run()
