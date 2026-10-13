import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum PortChecker {
    /// Where the last port the backend ran on is remembered (#218).
    static let lastPortKey = "lastBackendPort"

    /// Ports a remembered value may name: above the privileged range, and
    /// within what TCP can address.
    static let usableRange = 1024...65535

    /// Which port to start the backend on (#218): the one it used last time
    /// if that port is free, otherwise a fresh free one.
    ///
    /// The page's `localStorage` belongs to its origin, and the origin
    /// includes the port, so the same port keeps the page's preferences from
    /// one launch to the next. `PagePreferences` keeps them whatever the
    /// port; this just makes the common case the easy one. Anything odd —
    /// no remembered port, a port out of range, a port in use (another copy
    /// of the app, a PyCharm run, a server the last launch left behind) —
    /// falls back to what the app always did, so this can never stop a start.
    static func choosePort(
        remembered: Int?, isFree: (Int) -> Bool, findFree: () -> Int
    ) -> Int {
        if let port = remembered, usableRange.contains(port), isFree(port) {
            return port
        }
        return findFree()
    }

    static func rememberedPort(in defaults: UserDefaults = .standard) -> Int? {
        let port = defaults.integer(forKey: lastPortKey)
        return usableRange.contains(port) ? port : nil
    }

    static func remember(_ port: Int, in defaults: UserDefaults = .standard) {
        defaults.set(port, forKey: lastPortKey)
    }

    /// Whether a bind on 127.0.0.1:`port` succeeds right now. The socket is
    /// closed again at once, so there is a window before uvicorn binds;
    /// uvicorn reports its own failure if someone takes it in between.
    /// `SO_REUSEADDR`, as uvicorn sets it, so a connection the last server
    /// left in TIME_WAIT doesn't count as "in use".
    static func isFree(_ port: Int) -> Bool {
        guard usableRange.contains(port) else { return false }
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    /// Find a free port by binding to port 0 and reading the OS-assigned port
    static func findFreePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 0 }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // Let the OS pick
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        var addrCopy = addr
        let bindResult = withUnsafePointer(to: &addrCopy) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 0 }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addrCopy) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        guard nameResult == 0 else { return 0 }

        return Int(UInt16(bigEndian: addrCopy.sin_port))
    }

    /// Check if a port is currently in use
    static func isPortInUse(_ port: Int) async -> Bool {
        let result = try? await Shell.run(
            "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        )
        guard let result else { return false }
        return result.exitCode == 0
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get the PID using a port, if any
    static func pidOnPort(_ port: Int) async -> Int32? {
        let result = try? await Shell.run(
            "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        )
        guard let result, result.exitCode == 0 else { return nil }
        let pidStr = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(pidStr.split(separator: "\n").first ?? "")
    }
}
