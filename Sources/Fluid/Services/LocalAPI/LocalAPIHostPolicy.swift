import Foundation

/// Accepts only requests addressed to the loopback listener itself.
///
/// The listener already refuses non-loopback peers, but a web page in a local browser
/// can still reach 127.0.0.1 through a hostname it controls (DNS rebinding). Such a
/// request carries the attacker's hostname in its Host header, so checking the header
/// keeps meeting transcripts and history out of reach of web pages.
enum LocalAPIHostPolicy {
    static func isAllowed(host: String?, port: UInt16) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else {
            return false
        }
        let allowedNames = ["127.0.0.1", "localhost", "[::1]"]
        return allowedNames.contains { host == $0 || host == "\($0):\(port)" }
    }
}
