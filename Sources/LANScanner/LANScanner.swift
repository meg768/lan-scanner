import Foundation
import Network

actor LANScanner {
    private let maxConcurrentPings = 32

    private let servicePorts = [
        NetworkService(name: "ssh", port: 22),
        NetworkService(name: "ftp", port: 21),
        NetworkService(name: "http", port: 80),
        NetworkService(name: "https", port: 443),
        NetworkService(name: "smb", port: 445),
        NetworkService(name: "afp", port: 548),
        NetworkService(name: "mqtt", port: 1883),
        NetworkService(name: "postgresql", port: 5432),
        NetworkService(name: "mysql", port: 3306),
        NetworkService(name: "mssql", port: 1433),
        NetworkService(name: "redis", port: 6379),
        NetworkService(name: "vnc", port: 5900),
        NetworkService(name: "homebridge", port: 8581),
        NetworkService(name: "node-red", port: 1880),
        NetworkService(name: "home assistant", port: 8123)
    ]

    func scan(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [NetworkDevice] {
        guard let network = Self.localNetwork() else {
            throw ScannerError.noLocalNetwork
        }

        let hosts = (1...254).map { "\(network.prefix).\($0)" }
        let hostSet = Set(hosts)
        let total = hosts.count
        var completed = 0

        for chunk in hosts.chunked(into: maxConcurrentPings) {
            await withTaskGroup(of: Void.self) { group in
                for host in chunk {
                    group.addTask {
                        await self.ping(host)
                    }
                }

                for await _ in group {
                    completed += 1
                    progress(completed, total)
                }
            }
        }

        let devices = await Self.arpDevices(hostSet: hostSet)
        return await resolveNames(for: devices).sorted {
            Self.ipSortKey($0.ipAddress).lexicographicallyPrecedes(Self.ipSortKey($1.ipAddress))
        }
    }

    func scanServices(for devices: [NetworkDevice]) async -> [NetworkDevice] {
        var scannedDevices: [NetworkDevice] = []

        for chunk in devices.chunked(into: 3) {
            await withTaskGroup(of: NetworkDevice.self) { group in
                for device in chunk {
                    group.addTask {
                        var nextDevice = device
                        nextDevice.services = await self.openServices(for: device.ipAddress)
                        return nextDevice
                    }
                }

                for await device in group {
                    scannedDevices.append(device)
                }
            }
        }

        return scannedDevices.sorted {
            Self.ipSortKey($0.ipAddress).lexicographicallyPrecedes(Self.ipSortKey($1.ipAddress))
        }
    }

    func scanServices(for device: NetworkDevice) async -> NetworkDevice {
        var nextDevice = device
        nextDevice.services = await openServices(for: device.ipAddress)
        return nextDevice
    }

    @discardableResult
    private func ping(_ host: String) async -> Bool {
        let result = await Self.run("/sbin/ping", arguments: ["-c", "1", "-W", "250", host], timeout: 1.25)
        return result.exitCode == 0
    }

    private func openServices(for host: String) async -> [NetworkService] {
        var services: [NetworkService] = []

        for service in servicePorts {
            if await Self.canConnect(host: host, port: service.port) {
                services.append(service)
            }
        }

        return services
    }

    private static func canConnect(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let queue = DispatchQueue.global(qos: .utility)
            let resumer = ConnectionProbeResumer(continuation: continuation)

            @Sendable func finish(_ value: Bool) {
                resumer.finish(value, connection: connection)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.45) {
                finish(false)
            }
        }
    }

    static func localNetwork() -> LocalNetwork? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }

        defer {
            freeifaddrs(interfaces)
        }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        var candidates: [LocalNetwork] = []

        while let current = pointer {
            defer {
                pointer = current.pointee.ifa_next
            }

            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)

            guard
                flags & IFF_UP != 0,
                flags & IFF_LOOPBACK == 0,
                interface.ifa_addr.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard
                let address = ipv4String(interface.ifa_addr),
                let netmask = ipv4String(interface.ifa_netmask),
                isPrivateAddress(address),
                let prefix = prefix24(from: address)
            else {
                continue
            }

            candidates.append(LocalNetwork(interfaceName: name, address: address, netmask: netmask, prefix: prefix))
        }

        return candidates.first { $0.interfaceName == "en0" } ?? candidates.first
    }

    private static func ipv4String(_ socketAddress: UnsafePointer<sockaddr>) -> String? {
        var address = socketAddress.pointee
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4Pointer in
                var sinAddress = ipv4Pointer.pointee.sin_addr
                guard inet_ntop(AF_INET, &sinAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }

                return String(cString: buffer)
            }
        }
    }

    private static func isPrivateAddress(_ address: String) -> Bool {
        address.hasPrefix("10.")
            || address.hasPrefix("192.168.")
            || address.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
    }

    private static func prefix24(from address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else {
            return nil
        }

        return parts.prefix(3).joined(separator: ".")
    }

    private static func arpDevices(hostSet: Set<String>) async -> [NetworkDevice] {
        let result = await run("/usr/sbin/arp", arguments: ["-an"], timeout: 15)
        guard result.exitCode == 0 else {
            return []
        }

        var devicesByIP: [String: NetworkDevice] = [:]
        let pattern = #"^\S+\s+\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]+|incomplete)"#

        for line in result.output.split(separator: "\n") {
            guard
                let match = line.range(of: pattern, options: .regularExpression)
            else {
                continue
            }

            let matchedLine = String(line[match])
            let parts = matchedLine.split(separator: " ")
            guard
                let ipPart = parts.first(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }),
                let macIndex = parts.firstIndex(of: "at"),
                parts.indices.contains(parts.index(after: macIndex))
            else {
                continue
            }

            let ip = ipPart.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let macValue = String(parts[parts.index(after: macIndex)])
            guard hostSet.contains(ip), macValue.lowercased() != "incomplete" else {
                continue
            }

            let mac = normalizeMAC(macValue)
            devicesByIP[ip] = NetworkDevice(
                ipAddress: ip,
                hostname: nil,
                macAddress: mac,
                vendor: vendorName(for: mac),
                responseTimeMS: nil,
                services: [],
                lastSeen: Date()
            )
        }

        return Array(devicesByIP.values)
    }

    private func resolveNames(for devices: [NetworkDevice]) async -> [NetworkDevice] {
        var namedDevices: [NetworkDevice] = []

        for chunk in devices.chunked(into: 16) {
            await withTaskGroup(of: NetworkDevice.self) { group in
                for device in chunk {
                    group.addTask {
                        var nextDevice = device
                        nextDevice.hostname = await Self.dscacheName(for: device.ipAddress)
                        return nextDevice
                    }
                }

                for await device in group {
                    namedDevices.append(device)
                }
            }
        }

        return namedDevices
    }

    private static func dscacheName(for host: String) async -> String? {
        let result = await run("/usr/bin/dscacheutil", arguments: ["-q", "host", "-a", "ip_address", host], timeout: 0.75)
        guard result.exitCode == 0 else {
            return nil
        }

        guard
            let nameLine = result.output.split(separator: "\n").first(where: { $0.hasPrefix("name:") })
        else {
            return nil
        }

        let name = String(nameLine)
            .replacingOccurrences(of: "name:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    private static func vendorName(for macAddress: String) -> String? {
        let prefix = macAddress
            .split(separator: ":")
            .prefix(3)
            .joined(separator: ":")
            .lowercased()

        let vendors = [
            "b8:27:eb": "Raspberry Pi",
            "dc:a6:32": "Raspberry Pi",
            "e4:5f:01": "Raspberry Pi",
            "d8:3a:dd": "Raspberry Pi",
            "f4:5c:89": "Apple",
            "a4:83:e7": "Apple",
            "3c:22:fb": "Apple",
            "f0:18:98": "Apple",
            "70:cd:60": "Apple",
            "00:17:88": "Philips Hue",
            "ec:b5:fa": "Homey"
        ]

        return vendors[prefix]
    }

    private static func normalizeMAC(_ mac: String) -> String {
        mac.split(separator: ":")
            .map { part in
                part.count == 1 ? "0\(part)" : String(part)
            }
            .joined(separator: ":")
            .lowercased()
    }

    private static func ipSortKey(_ ip: String) -> [Int] {
        ip.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func run(_ path: String, arguments: [String], timeout: TimeInterval) async -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        return await withCheckedContinuation { continuation in
            let resumer = CommandResumer(continuation: continuation, process: process, pipe: pipe)

            process.terminationHandler = { finishedProcess in
                resumer.finish(exitCode: finishedProcess.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                resumer.finish(exitCode: -1, output: error.localizedDescription)
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                    resumer.finish(exitCode: -1)
                }
            }
        }
    }

    private static func runSync(_ path: String, arguments: [String], timeout: TimeInterval = 1.0) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(exitCode: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }

        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct CommandResult {
    let exitCode: Int32
    let output: String
}

private final class CommandResumer: @unchecked Sendable {
    private let continuation: CheckedContinuation<CommandResult, Never>
    private let process: Process
    private let pipe: Pipe
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<CommandResult, Never>, process: Process, pipe: Pipe) {
        self.continuation = continuation
        self.process = process
        self.pipe = pipe
    }

    func finish(exitCode: Int32, output: String? = nil) {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !didResume else {
            return
        }

        didResume = true
        process.terminationHandler = nil

        let resolvedOutput: String
        if let output {
            resolvedOutput = output
        } else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            resolvedOutput = String(data: data, encoding: .utf8) ?? ""
        }

        continuation.resume(returning: CommandResult(exitCode: exitCode, output: resolvedOutput))
    }
}

enum ScannerError: LocalizedError {
    case noLocalNetwork

    var errorDescription: String? {
        switch self {
        case .noLocalNetwork:
            return "No private IPv4 network found."
        }
    }
}

private final class ConnectionProbeResumer: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool, connection: NWConnection) {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !didResume else {
            return
        }

        didResume = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}
