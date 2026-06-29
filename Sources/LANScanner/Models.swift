import Foundation

struct NetworkDevice: Identifiable, Hashable {
    var id: String { ipAddress }

    let ipAddress: String
    var hostname: String?
    var dnsName: String?
    var macAddress: String?
    var vendor: String?
    var responseTimeMS: Double?
    var services: [NetworkService]
    var lastSeen: Date

    var displayName: String {
        hostname?.isEmpty == false ? hostname! : ipAddress
    }

    var tableName: String {
        displayName
    }

    var tableIPSortKey: String {
        ipAddress
            .split(separator: ".")
            .map { String(format: "%03d", Int($0) ?? 0) }
            .joined(separator: ".")
    }

    var addressText: String {
        guard let macAddress, !macAddress.isEmpty else {
            return ipAddress
        }

        return "\(ipAddress) (\(macAddress))"
    }

    var tableVendor: String {
        vendor ?? ""
    }

    var pingText: String {
        guard let responseTimeMS else {
            return "-"
        }

        if responseTimeMS < 10 {
            return String(format: "%.1f ms", responseTimeMS)
        }

        return "\(Int(responseTimeMS.rounded())) ms"
    }

    var tableServices: String {
        services
            .sorted { $0.port < $1.port }
            .map(\.name)
            .joined(separator: ", ")
    }
}

struct NetworkService: Identifiable, Hashable {
    let name: String
    let port: Int

    var id: Int { port }

    var systemImage: String {
        switch name {
        case "ssh":
            return "terminal"
        case "http", "https":
            return "globe"
        case "mqtt":
            return "dot.radiowaves.left.and.right"
        case "postgresql", "mysql", "mssql", "redis":
            return "cylinder.split.1x2"
        case "smb", "afp":
            return "externaldrive.connected.to.line.below"
        case "vnc":
            return "display"
        case "homebridge", "home assistant":
            return "house"
        case "node-red":
            return "point.3.connected.trianglepath.dotted"
        default:
            return "network"
        }
    }
}

struct DeviceInspection: Hashable {
    let likelyTypes: [String]
    let openServices: [DeviceInspectionItem]
    let systemFindings: [DeviceInspectionItem]
    let notes: [String]

    var hasFindings: Bool {
        !likelyTypes.isEmpty || !openServices.isEmpty || !systemFindings.isEmpty || !notes.isEmpty
    }
}

struct DeviceInspectionItem: Identifiable, Hashable {
    let name: String
    let detail: String
    let port: Int?
    let systemImage: String

    var id: String {
        if let port {
            return "\(name)-\(port)"
        }

        return name
    }
}

struct LocalNetwork: Hashable {
    let interfaceName: String
    let address: String
    let netmask: String
    let prefix: String

    var displayName: String {
        "\(prefix).0/24 via \(interfaceName)"
    }
}

enum ScanStatus: Equatable {
    case idle
    case scanning(String)
    case complete(String)
    case failed(String)

    var text: String {
        switch self {
        case .idle:
            return "Ready"
        case .scanning(let text), .complete(let text), .failed(let text):
            return text
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "circle"
        case .scanning:
            return "dot.radiowaves.left.and.right"
        case .complete:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}
