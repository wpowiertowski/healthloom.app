// Nested layout probe for the `scanSources` relative-path contract
// (round-4 item 12). This file is INTENTIONALLY inert: no declarations
// that could trip any source-scanning grep-test, no symbols any ban
// list names. `scanReportsRelativePaths` expects this file reported as
// `Nested/Probe.swift` — relative to the scanned root, not bare.
enum ScanFixtureProbe {
    static let relativePath = "Nested/Probe.swift"
}
