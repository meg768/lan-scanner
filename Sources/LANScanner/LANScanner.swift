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

    func inspect(device: NetworkDevice) async -> DeviceInspection {
        async let openServices = inspectOpenServices(for: device.ipAddress)
        let likelyTypes = Self.deviceHints(for: device)
        let services = await openServices
        let httpFindings = await Self.inspectHTTP(for: device.ipAddress, services: services)
        let sshFindings = services.contains { $0.name == "SSH" } ? await inspectSSH(device: device) : []
        let systemFindings = httpFindings + sshFindings
        let notes = Self.inspectionNotes(for: device, likelyTypes: likelyTypes, services: services, systemFindings: systemFindings)

        return DeviceInspection(
            likelyTypes: likelyTypes,
            openServices: services,
            systemFindings: systemFindings,
            notes: notes
        )
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

    private func inspectOpenServices(for host: String) async -> [DeviceInspectionItem] {
        let probes = [
            ServiceProbe(name: "SSH", detail: "Remote shell / Raspberry Pi admin", port: 22, systemImage: "terminal"),
            ServiceProbe(name: "FTP", detail: "File transfer", port: 21, systemImage: "folder"),
            ServiceProbe(name: "HTTP", detail: "Web UI, Apache, nginx or device portal", port: 80, systemImage: "globe"),
            ServiceProbe(name: "HTTPS", detail: "Secure web UI", port: 443, systemImage: "lock.globe"),
            ServiceProbe(name: "IPP / Printer", detail: "Printer protocol or CUPS", port: 631, systemImage: "printer"),
            ServiceProbe(name: "RTSP camera", detail: "Camera/video stream", port: 554, systemImage: "video"),
            ServiceProbe(name: "SMB", detail: "Windows/macOS file sharing", port: 445, systemImage: "externaldrive.connected.to.line.below"),
            ServiceProbe(name: "AFP", detail: "Apple file sharing", port: 548, systemImage: "externaldrive.connected.to.line.below"),
            ServiceProbe(name: "MQTT", detail: "IoT broker", port: 1883, systemImage: "dot.radiowaves.left.and.right"),
            ServiceProbe(name: "Node-RED", detail: "Automation dashboard", port: 1880, systemImage: "point.3.connected.trianglepath.dotted"),
            ServiceProbe(name: "Grafana / Node app", detail: "Dashboard or common Node.js app port", port: 3000, systemImage: "chart.xyaxis.line"),
            ServiceProbe(name: "Alt HTTP", detail: "Secondary web UI or proxy", port: 8080, systemImage: "globe"),
            ServiceProbe(name: "Jellyfin", detail: "Media server", port: 8096, systemImage: "play.rectangle"),
            ServiceProbe(name: "Home Assistant", detail: "Smart home server", port: 8123, systemImage: "house"),
            ServiceProbe(name: "Homebridge", detail: "HomeKit bridge", port: 8581, systemImage: "house.and.flag"),
            ServiceProbe(name: "Plex", detail: "Media server", port: 32400, systemImage: "play.tv"),
            ServiceProbe(name: "Printer RAW", detail: "JetDirect/raw printer socket", port: 9100, systemImage: "printer"),
            ServiceProbe(name: "MySQL / MariaDB", detail: "SQL database", port: 3306, systemImage: "cylinder.split.1x2"),
            ServiceProbe(name: "PostgreSQL", detail: "SQL database", port: 5432, systemImage: "cylinder.split.1x2"),
            ServiceProbe(name: "Microsoft SQL", detail: "SQL database", port: 1433, systemImage: "cylinder.split.1x2"),
            ServiceProbe(name: "Redis", detail: "Cache / queue", port: 6379, systemImage: "memorychip"),
            ServiceProbe(name: "VNC", detail: "Remote desktop", port: 5900, systemImage: "display"),
            ServiceProbe(name: "ADB", detail: "Android debug bridge", port: 5555, systemImage: "ladybug"),
            ServiceProbe(name: "Sonos", detail: "Speaker control/web endpoint", port: 1400, systemImage: "hifispeaker"),
            ServiceProbe(name: "HomeKit accessory", detail: "Common HomeKit accessory endpoint", port: 51826, systemImage: "homekit"),
            ServiceProbe(name: "RAOP / AirTunes", detail: "Apple audio streaming receiver", port: 5000, systemImage: "airplayaudio"),
            ServiceProbe(name: "Apple TV MediaRemote", detail: "Apple TV remote/media control", port: 49152, systemImage: "appletvremote.gen1"),
            ServiceProbe(name: "Apple TV Companion", detail: "Apple TV companion/remote pairing", port: 6466, systemImage: "appletvremote.gen1"),
            ServiceProbe(name: "AirPlay", detail: "Apple TV / AirPlay receiver", port: 7000, systemImage: "airplayvideo"),
            ServiceProbe(name: "AirPlay control", detail: "Apple TV / AirPlay control", port: 7100, systemImage: "airplayvideo"),
            ServiceProbe(name: "AirPlay alt", detail: "Alternate AirPlay receiver endpoint", port: 7001, systemImage: "airplayvideo"),
            ServiceProbe(name: "Google Cast HTTP", detail: "Chromecast / Google device web endpoint", port: 8008, systemImage: "tv"),
            ServiceProbe(name: "Google Cast", detail: "Chromecast / Google speaker display", port: 8009, systemImage: "tv"),
            ServiceProbe(name: "Samsung TV legacy", detail: "Older Samsung TV remote API", port: 55000, systemImage: "tv"),
            ServiceProbe(name: "Samsung DIAL", detail: "DIAL app-launch endpoint used by some TVs", port: 7676, systemImage: "tv"),
            ServiceProbe(name: "Samsung TV web", detail: "Samsung TV or Tizen web endpoint", port: 8000, systemImage: "tv"),
            ServiceProbe(name: "Samsung TV", detail: "Samsung TV remote API", port: 8001, systemImage: "tv"),
            ServiceProbe(name: "Samsung TV TLS", detail: "Samsung TV encrypted remote API", port: 8002, systemImage: "tv")
        ]

        return await withTaskGroup(of: DeviceInspectionItem?.self) { group in
            for probe in probes {
                group.addTask {
                    guard await Self.canConnect(host: host, port: probe.port) else {
                        return nil
                    }

                    return DeviceInspectionItem(
                        name: probe.name,
                        detail: probe.detail,
                        port: probe.port,
                        systemImage: probe.systemImage
                    )
                }
            }

            var items: [DeviceInspectionItem] = []
            for await item in group {
                if let item {
                    items.append(item)
                }
            }

            return items.sorted { ($0.port ?? 0) < ($1.port ?? 0) }
        }
    }

    private func inspectSSH(device: NetworkDevice) async -> [DeviceInspectionItem] {
        let users = Self.sshUsers()

        for user in users {
            let result = await Self.run(
                "/usr/bin/ssh",
                arguments: Self.sshArguments(user: user, host: device.ipAddress),
                timeout: 20
            )

            if result.exitCode == 0 {
                return Self.sshFindings(from: result.output, user: user)
            }
        }

        return [
            DeviceInspectionItem(
                name: "SSH passwordless login failed",
                detail: "SSH is open, but passwordless public-key login failed for \(users.joined(separator: ", ")).",
                port: nil,
                systemImage: "key.slash"
            )
        ]
    }

    private static func inspectHTTP(for host: String, services: [DeviceInspectionItem]) async -> [DeviceInspectionItem] {
        let ports = services.compactMap { service -> HTTPProbe? in
            switch service.name {
            case "HTTP":
                return HTTPProbe(scheme: "http", port: 80)
            case "HTTPS":
                return HTTPProbe(scheme: "https", port: 443)
            case "Alt HTTP":
                return HTTPProbe(scheme: "http", port: 8080)
            case "Grafana / Node app":
                return HTTPProbe(scheme: "http", port: 3000)
            case "Node-RED":
                return HTTPProbe(scheme: "http", port: 1880)
            case "Home Assistant":
                return HTTPProbe(scheme: "http", port: 8123)
            case "Homebridge":
                return HTTPProbe(scheme: "http", port: 8581)
            case "Jellyfin":
                return HTTPProbe(scheme: "http", port: 8096)
            case "Plex":
                return HTTPProbe(scheme: "http", port: 32400)
            case "Google Cast HTTP":
                return HTTPProbe(scheme: "http", port: 8008)
            case "Sonos":
                return HTTPProbe(scheme: "http", port: 1400)
            case "IPP / Printer":
                return HTTPProbe(scheme: "http", port: 631)
            default:
                return nil
            }
        }

        return await withTaskGroup(of: DeviceInspectionItem?.self) { group in
            for probe in ports {
                group.addTask {
                    await httpFinding(for: host, probe: probe)
                }
            }

            var findings: [DeviceInspectionItem] = []
            for await finding in group {
                if let finding {
                    findings.append(finding)
                }
            }

            return findings.sorted { ($0.port ?? 0) < ($1.port ?? 0) }
        }
    }

    private static func httpFinding(for host: String, probe: HTTPProbe) async -> DeviceInspectionItem? {
        let url = "\(probe.scheme)://\(host):\(probe.port)/"
        let result = await run(
            "/usr/bin/curl",
            arguments: ["-k", "-L", "--max-time", "2", "-A", "LANScanner/1.0", "-i", url],
            timeout: 3
        )

        guard result.exitCode == 0, !result.output.isEmpty else {
            return nil
        }

        let title = htmlTitle(from: result.output)
        let server = headerValue("Server", from: result.output)
        let poweredBy = headerValue("X-Powered-By", from: result.output)
        let detail = [
            title.map { "title: \($0)" },
            server.map { "server: \($0)" },
            poweredBy.map { "powered by: \($0)" }
        ]
            .compactMap { $0 }
            .joined(separator: " | ")

        guard !detail.isEmpty else {
            return nil
        }

        return DeviceInspectionItem(
            name: "Web fingerprint",
            detail: "\(url) - \(detail)",
            port: probe.port,
            systemImage: "doc.text.magnifyingglass"
        )
    }

    private static func headerValue(_ name: String, from output: String) -> String? {
        output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.lowercased().hasPrefix("\(name.lowercased()):") }?
            .split(separator: ":", maxSplits: 1)
            .last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func htmlTitle(from output: String) -> String? {
        guard let range = output.range(of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }

        return output[range]
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sshUsers() -> [String] {
        ["pi", "root"]
    }

    private static func sshArguments(user: String, host: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ConnectTimeout=2",
            "-o", "StrictHostKeyChecking=accept-new",
            "\(user)@\(host)",
            sshInspectionScript
        ]
    }

    private static let sshInspectionScript = """
    sh -lc 'kv(){ printf "%s=%s\\n" "$1" "$2"; }; \
    kv SSH_USER "$(id -un 2>/dev/null)"; \
    kv HOSTNAME "$(hostname 2>/dev/null)"; \
    kv OS "$(sh -c ". /etc/os-release 2>/dev/null && printf %s \\"$PRETTY_NAME\\"" 2>/dev/null)"; \
    kv KERNEL "$(uname -srmo 2>/dev/null)"; \
    kv UPTIME "$(uptime -p 2>/dev/null)"; \
    kv ARCH "$(uname -m 2>/dev/null)"; \
    kv NODE "$(node --version 2>/dev/null)"; \
    kv NPM "$(npm --version 2>/dev/null)"; \
    kv PYTHON3 "$(python3 --version 2>/dev/null)"; \
    kv PYTHON "$(python --version 2>/dev/null)"; \
    kv PM2 "$(pm2 --version 2>/dev/null)"; \
    kv DOCKER "$(docker --version 2>/dev/null)"; \
    kv DOCKER_CONTAINERS "$(docker ps --format "{{.Names}}" 2>/dev/null | paste -sd "," -)"; \
    kv APACHE "$(apache2 -v 2>/dev/null | head -1)"; \
    kv NGINX "$(nginx -v 2>&1 | head -1)"; \
    kv MYSQL "$(mysql --version 2>/dev/null)"; \
    kv MARIADB "$(mariadb --version 2>/dev/null)"; \
    kv POSTGRES "$(psql --version 2>/dev/null)"; \
    kv REDIS "$(redis-server --version 2>/dev/null | head -1)"; \
    kv MOSQUITTO "$(mosquitto -h 2>/dev/null | head -1)"; \
    kv JAVA "$(java -version 2>&1 | head -1)"; \
    kv GO "$(go version 2>/dev/null)"; \
    kv RUST "$(rustc --version 2>/dev/null)"; \
    kv DISK_ROOT "$(df -h / 2>/dev/null | awk "NR==2{print \\$3 \\" used of \\" \\$2 \\" (\\" \\$5 \\")\\"}")"; \
    kv MEMORY "$(free -h 2>/dev/null | awk "/^Mem:/{print \\$3 \\" used of \\" \\$2}")"; \
    kv SYSTEMD_MATCHES "$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk "{print \\$1}" | grep -Ei "node|pm2|docker|nginx|apache|mysql|mariadb|postgres|redis|mosquitto|home|assistant|nodered|grafana|influx|prometheus" | head -20 | paste -sd "," -)"; \
    kv HOME_DIRS "$(find /home -mindepth 1 -maxdepth 1 -type d -printf "%f " 2>/dev/null)"'
    """

    private static func sshFindings(from output: String, user: String) -> [DeviceInspectionItem] {
        let values = Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return nil
            }

            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return nil
            }

            return (key, value)
        })

        var findings: [DeviceInspectionItem] = [
            DeviceInspectionItem(name: "SSH passwordless login", detail: "Passwordless login succeeded as \(values["SSH_USER"] ?? user).", port: nil, systemImage: "key")
        ]

        func add(_ key: String, name: String, icon: String) {
            if let value = values[key] {
                findings.append(DeviceInspectionItem(name: name, detail: value, port: nil, systemImage: icon))
            }
        }

        add("OS", name: "Operating system", icon: "desktopcomputer")
        add("KERNEL", name: "Kernel", icon: "cpu")
        add("UPTIME", name: "Uptime", icon: "clock")
        add("ARCH", name: "Architecture", icon: "memorychip")
        add("NODE", name: "Node.js", icon: "hexagon")
        add("NPM", name: "npm", icon: "shippingbox")
        add("PYTHON3", name: "Python 3", icon: "chevron.left.forwardslash.chevron.right")
        add("PYTHON", name: "Python", icon: "chevron.left.forwardslash.chevron.right")
        add("PM2", name: "PM2", icon: "bolt.horizontal")
        add("DOCKER", name: "Docker", icon: "shippingbox")
        add("DOCKER_CONTAINERS", name: "Docker containers", icon: "square.stack.3d.up")
        add("APACHE", name: "Apache", icon: "globe")
        add("NGINX", name: "nginx", icon: "globe")
        add("MYSQL", name: "MySQL", icon: "cylinder.split.1x2")
        add("MARIADB", name: "MariaDB", icon: "cylinder.split.1x2")
        add("POSTGRES", name: "PostgreSQL", icon: "cylinder.split.1x2")
        add("REDIS", name: "Redis", icon: "memorychip")
        add("MOSQUITTO", name: "Mosquitto", icon: "dot.radiowaves.left.and.right")
        add("JAVA", name: "Java", icon: "cup.and.saucer")
        add("GO", name: "Go", icon: "chevron.left.forwardslash.chevron.right")
        add("RUST", name: "Rust", icon: "gearshape.2")
        add("SYSTEMD_MATCHES", name: "Running services", icon: "list.bullet.rectangle")
        add("DISK_ROOT", name: "Root disk", icon: "internaldrive")
        add("MEMORY", name: "Memory", icon: "memorychip")
        add("HOME_DIRS", name: "Home directories", icon: "house")

        return findings
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

    private static func deviceHints(for device: NetworkDevice) -> [String] {
        let haystack = [
            device.hostname,
            device.dnsName,
            device.vendor,
            device.macAddress
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        var hints: [String] = []

        func add(_ hint: String, if condition: Bool) {
            if condition, !hints.contains(hint) {
                hints.append(hint)
            }
        }

        add("Raspberry Pi", if: haystack.contains("raspberry") || haystack.contains("pi-") || haystack.contains("b8:27:eb") || haystack.contains("dc:a6:32"))
        add("Apple device", if: haystack.contains("apple") || haystack.contains("macbook") || haystack.contains("iphone") || haystack.contains("ipad") || haystack.contains("watch"))
        add("Apple TV / AirPlay candidate", if: haystack.contains("apple-tv") || haystack.contains("appletv") || haystack.contains("airplay") || haystack.contains("tv.local") || haystack.contains("tv.lan"))
        add("Samsung device", if: haystack.contains("samsung"))
        add("Samsung Smart TV candidate", if: haystack.contains("samsung") && (haystack.contains("tv") || haystack.contains("tizen") || haystack == "samsung"))
        add("Google / Nest / Chromecast device", if: haystack.contains("google") || haystack.contains("chromecast") || haystack.contains("nest") || haystack.contains("home-mini"))
        add("Philips Hue / lighting", if: haystack.contains("philips") || haystack.contains("hue"))
        add("Audio device", if: haystack.contains("audio") || haystack.contains("speaker") || haystack.contains("sonos"))
        add("Vacuum / robot candidate", if: haystack.contains("roborock") || haystack.contains("roomba") || haystack.contains("vacuum") || haystack.contains("dreame") || haystack.contains("ecovacs"))
        add("Printer candidate", if: haystack.contains("printer") || haystack.contains("epson") || haystack.contains("brother") || haystack.contains("canon") || haystack.contains("hp "))
        add("Camera candidate", if: haystack.contains("camera") || haystack.contains("cam") || haystack.contains("rtsp"))
        add("Router / gateway candidate", if: device.ipAddress.hasSuffix(".1") || haystack.contains("router") || haystack.contains("gateway"))

        return hints
    }

    private static func inspectionNotes(for device: NetworkDevice, likelyTypes: [String], services: [DeviceInspectionItem], systemFindings: [DeviceInspectionItem]) -> [String] {
        var notes: [String] = []
        let serviceNames = Set(services.map(\.name))
        let systemFindingNames = Set(systemFindings.map(\.name))
        let isRaspberryPi = likelyTypes.contains("Raspberry Pi")

        if isRaspberryPi {
            if systemFindingNames.contains("SSH passwordless login") {
                notes.append("Raspberry Pi SSH inspection succeeded. Installed runtimes and services above came from the device itself.")
            } else if serviceNames.contains("SSH") {
                notes.append("Raspberry Pi with SSH open, but passwordless public-key login did not succeed for pi or root.")
            } else {
                notes.append("Raspberry Pi candidate, but SSH is not open on port 22.")
            }
        }

        if serviceNames.contains("HTTP") || serviceNames.contains("HTTPS") || serviceNames.contains("Alt HTTP") {
            notes.append("Web UI detected. Title/server fingerprints above can identify routers, NAS, dashboards, cameras and smart-home devices.")
        }

        if serviceNames.contains("MySQL / MariaDB") || serviceNames.contains("PostgreSQL") || serviceNames.contains("Microsoft SQL") {
            notes.append("Database port detected. Treat as a server or app host, not just a simple client device.")
        }

        if serviceNames.contains("Grafana / Node app") || serviceNames.contains("Node-RED") {
            notes.append("Node.js-style service detected. Could be an automation host, dashboard or custom app.")
        }

        if serviceNames.contains("MQTT") {
            notes.append("MQTT is open. This is likely an IoT broker or smart-home integration point.")
        }

        let appleTVServices = ["RAOP / AirTunes", "Apple TV MediaRemote", "Apple TV Companion", "AirPlay", "AirPlay control", "AirPlay alt", "HomeKit accessory"]
        let hasAppleTVService = appleTVServices.contains { serviceNames.contains($0) }
        let isAppleTVCandidate = likelyTypes.contains("Apple TV / AirPlay candidate")

        if serviceNames.contains("RAOP / AirTunes") {
            notes.append("RAOP/AirTunes is open. Apple TV, AirPort Express or AirPlay audio receiver is plausible.")
        }

        if serviceNames.contains("Apple TV MediaRemote") {
            notes.append("Apple TV MediaRemote endpoint detected. This is a strong Apple TV signal.")
        }

        if serviceNames.contains("Apple TV Companion") {
            notes.append("Apple TV companion/remote pairing endpoint detected.")
        }

        if serviceNames.contains("AirPlay") || serviceNames.contains("AirPlay control") || serviceNames.contains("AirPlay alt") {
            notes.append("AirPlay video/control endpoint detected. Apple TV or AirPlay receiver is plausible.")
        }

        if isAppleTVCandidate, !hasAppleTVService {
            notes.append("Apple TV/AirPlay candidate, but no Apple TV control ports answered. It may be asleep, on another interface, or only advertising through Bonjour.")
        }

        if serviceNames.contains("Google Cast") {
            notes.append("Google Cast port detected. Chromecast, Nest speaker or display is plausible.")
        }

        let samsungTVServices = ["Samsung TV", "Samsung TV TLS", "Samsung TV legacy", "Samsung DIAL", "Samsung TV web"]
        let hasSamsungTVService = samsungTVServices.contains { serviceNames.contains($0) }
        let isSamsungDevice = likelyTypes.contains("Samsung device") || likelyTypes.contains("Samsung Smart TV candidate")

        if serviceNames.contains("Samsung TV legacy") {
            notes.append("Older Samsung TV remote API detected. This is a strong TV signal.")
        }

        if serviceNames.contains("Samsung DIAL") {
            notes.append("Samsung/DIAL app-launch endpoint detected. Smart TV is likely.")
        }

        if serviceNames.contains("Samsung TV web") {
            notes.append("Samsung/Tizen-style web endpoint detected.")
        }

        if serviceNames.contains("Samsung TV") {
            notes.append("Samsung TV remote API port detected. Smart TV is likely.")
        }

        if serviceNames.contains("Samsung TV TLS") {
            notes.append("Samsung encrypted remote API port detected. Smart TV is likely.")
        }

        if isSamsungDevice, !hasSamsungTVService {
            notes.append("Samsung device found, but no Samsung TV local-control ports answered. It may be a phone/tablet, or a TV in standby/offline mode. If it is the TV, turn it on and inspect again.")
        }

        if serviceNames.contains("IPP / Printer") || serviceNames.contains("Printer RAW") {
            notes.append("Printer-style port detected. This is likely a printer, print server or CUPS host.")
        }

        if serviceNames.contains("RTSP camera") {
            notes.append("RTSP is open. Network camera, video doorbell or media streamer is plausible.")
        }

        if serviceNames.contains("ADB") {
            notes.append("ADB is open. Android TV, phone/tablet in debug mode or embedded Android device is plausible.")
        }

        if serviceNames.contains("Sonos") {
            notes.append("Sonos-style speaker endpoint detected.")
        }

        if serviceNames.contains("HomeKit accessory") || serviceNames.contains("Homebridge") {
            notes.append("HomeKit/Homebridge endpoint detected. This may be a bridge, smart-home hub or accessory.")
        }

        if serviceNames.contains("Plex") || serviceNames.contains("Jellyfin") {
            notes.append("Media server endpoint detected.")
        }

        if let macAddress = device.macAddress,
           let firstByte = macAddress.split(separator: ":").first,
           let value = UInt8(firstByte, radix: 16),
           value & 2 == 2 {
            notes.append("MAC is locally administered, so vendor and device-type guesses can be masked or randomized.")
        }

        if services.isEmpty, !isSamsungDevice, !isAppleTVCandidate {
            notes.append("No known inspected ports responded. It may still be a phone, watch, TV, sensor, vacuum or sleeping device.")
        }

        return notes
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
                dnsName: nil,
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
                        nextDevice.dnsName = await Self.reverseDNSName(for: device.ipAddress)
                        nextDevice.hostname = Self.shortHostname(from: nextDevice.dnsName)
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

    private static func reverseDNSName(for host: String) async -> String? {
        if let name = await dscacheName(for: host) {
            return name
        }

        return await digName(for: host)
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

    private static func digName(for host: String) async -> String? {
        let result = await run("/usr/bin/dig", arguments: ["+short", "-x", host], timeout: 0.9)
        guard result.exitCode == 0 else {
            return nil
        }

        return result.output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func shortHostname(from dnsName: String?) -> String? {
        guard let dnsName, !dnsName.isEmpty else {
            return nil
        }

        for suffix in [".lan", ".local"] where dnsName.localizedCaseInsensitiveContains(suffix) {
            if dnsName.lowercased().hasSuffix(suffix) {
                return String(dnsName.dropLast(suffix.count))
            }
        }

        return dnsName
    }

    private static func vendorName(for macAddress: String) -> String? {
        let prefix = macAddress
            .split(separator: ":")
            .prefix(3)
            .joined(separator: ":")
            .lowercased()

        let vendors = [
            "b8:27:eb": "Raspberry Pi Foundation",
            "dc:a6:32": "Raspberry Pi Foundation",
            "e4:5f:01": "Raspberry Pi Foundation",
            "d8:3a:dd": "Raspberry Pi Foundation",
            "f4:5c:89": "Apple",
            "a4:83:e7": "Apple",
            "3c:22:fb": "Apple",
            "f0:18:98": "Apple",
            "70:cd:60": "Apple",
            "3c:31:74": "Google, Inc.",
            "7c:64:56": "Samsung Electronics Co.,Ltd",
            "00:17:88": "Philips Hue",
            "e8:c1:d7": "Philips",
            "00:22:6c": "LinkSprite Technologies, Inc.",
            "6c:19:8f": "D-Link International",
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

private struct ServiceProbe: Sendable {
    let name: String
    let detail: String
    let port: Int
    let systemImage: String
}

private struct HTTPProbe: Sendable {
    let scheme: String
    let port: Int
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
