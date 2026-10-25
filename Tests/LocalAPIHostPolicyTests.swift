import Foundation

@main
struct LocalAPIHostPolicyTests {
    static func main() {
        let port: UInt16 = 47_733

        for host in ["127.0.0.1:47733", "localhost:47733", "[::1]:47733", "127.0.0.1", "LOCALHOST:47733", " localhost:47733 "] {
            precondition(LocalAPIHostPolicy.isAllowed(host: host, port: port), "Expected \(host) to be allowed")
        }

        let rejected: [String?] = [
            nil,
            "",
            "evil.example:47733",
            "localhost.evil.example:47733",
            "127.0.0.1.nip.io:47733",
            "127.0.0.1:8080",
            "localhost:47734",
            "0.0.0.0:47733",
        ]
        for host in rejected {
            precondition(!LocalAPIHostPolicy.isAllowed(host: host, port: port), "Expected \(host ?? "nil") to be rejected")
        }

        print("LocalAPIHostPolicyTests passed")
    }
}
