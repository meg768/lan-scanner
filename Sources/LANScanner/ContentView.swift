import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var store = ScannerStore()
    @State private var searchText = ""
    @State private var devicePanelWidth: CGFloat?

    var body: some View {
        VStack(spacing: 12) {
            HeaderPanel(
                network: store.localNetwork,
                isScanning: store.isScanning,
                onScan: store.scan
            )

            ScannerSplitView(
                devices: filteredDevices,
                selectedDevice: store.selectedDevice,
                isScanningServices: store.isScanningSelectedServices,
                devicePanelWidth: $devicePanelWidth,
                onSelect: store.selectDevice
            )

            StatusBar(status: store.status, deviceCount: store.devices.count)
        }
        .id("\(appearance.mode.rawValue)-\(appearance.surface.rawValue)")
        .padding(12)
        .frame(minWidth: 980, minHeight: 640)
        .background(AppColors.pageBackground)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.scan()
                } label: {
                    Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(store.isScanning)

                Button {
                    searchText = ""
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }

            ToolbarItem {
                FilterField(text: $searchText)
                    .frame(width: 260)
            }
        }
        .onAppear {
            store.refreshLocalNetwork()
        }
        .modifier(FunctionKeyShortcut(keyCode: 97, functionKey: NSF6FunctionKey) {
            appearance.toggle(over: colorScheme)
        })
        .modifier(FunctionKeyShortcut(keyCode: 99, functionKey: NSF3FunctionKey) {
            appearance.cycleSurface()
        })
    }

    private var filteredDevices: [NetworkDevice] {
        store.devices.filter { device in
            guard !searchText.isEmpty else {
                return true
            }

            let haystack = [
                device.ipAddress,
                device.hostname,
                device.macAddress,
                device.vendor,
                device.services.map(\.name).joined(separator: " ")
            ]
                .compactMap { $0 }
                .joined(separator: " ")

            return haystack.localizedCaseInsensitiveContains(searchText)
        }
    }
}

@MainActor
final class ScannerStore: ObservableObject {
    @Published var devices: [NetworkDevice] = []
    @Published var selectedDevice: NetworkDevice?
    @Published var localNetwork = LANScanner.localNetwork()
    @Published var status: ScanStatus = .idle
    @Published var isScanning = false
    @Published var isScanningSelectedServices = false

    private let scanner = LANScanner()
    private var serviceScanTask: Task<Void, Never>?

    func refreshLocalNetwork() {
        localNetwork = LANScanner.localNetwork()
    }

    func scan() {
        guard !isScanning else {
            return
        }

        isScanning = true
        status = .scanning("Scanning local network...")
        refreshLocalNetwork()

        Task {
            do {
                let foundDevices = try await scanner.scan { completed, total in
                    Task { @MainActor in
                        self.status = .scanning("Scanned \(completed) of \(total) addresses...")
                    }
                }

                devices = foundDevices
                selectedDevice = foundDevices.first

                status = .complete("Found \(foundDevices.count) online devices.")
            } catch {
                status = .failed(error.localizedDescription)
            }

            isScanning = false
        }
    }

    func selectDevice(_ device: NetworkDevice) {
        selectedDevice = device
        serviceScanTask?.cancel()

        guard device.services.isEmpty else {
            isScanningSelectedServices = false
            return
        }

        isScanningSelectedServices = true
        serviceScanTask = Task {
            let scannedDevice = await scanner.scanServices(for: device)

            guard !Task.isCancelled else {
                return
            }

            if let index = devices.firstIndex(where: { $0.id == scannedDevice.id }) {
                devices[index] = scannedDevice
            }

            if selectedDevice?.id == scannedDevice.id {
                selectedDevice = scannedDevice
            }

            isScanningSelectedServices = false
        }
    }
}

struct HeaderPanel: View {
    let network: LocalNetwork?
    let isScanning: Bool
    let onScan: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Network")
                        .font(.system(size: 14, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(AppColors.caption)

                    Button {
                        onScan()
                    } label: {
                        IconPillLabel(isScanning ? "Scanning" : "Scan", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                }

                Text(network?.displayName ?? "No local IPv4 network")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppColors.heading)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AppColors.primaryStrong)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("LAN")
                        .font(.system(size: 28, weight: .bold))
                    Text("scanner")
                        .font(.system(size: 17, weight: .semibold, design: .serif).italic())
                }
            }
            .foregroundStyle(AppColors.primaryStrong)
        }
        .padding(18)
        .background(AppColors.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ScannerSplitView: View {
    let devices: [NetworkDevice]
    let selectedDevice: NetworkDevice?
    let isScanningServices: Bool
    @Binding var devicePanelWidth: CGFloat?
    let onSelect: (NetworkDevice) -> Void

    private let dividerWidth: CGFloat = 14
    private let minDeviceWidth: CGFloat = 360
    private let minDetailWidth: CGFloat = 320
    private let defaultDetailWidth: CGFloat = 380

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let deviceWidth = clampedDeviceWidth(for: availableWidth)

            HStack(spacing: 0) {
                DeviceListPanel(
                    devices: devices,
                    selectedDevice: selectedDevice,
                    onSelect: onSelect
                )
                .frame(width: deviceWidth)

                SplitDivider()
                    .frame(width: dividerWidth)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("ScannerSplitView"))
                            .onChanged { value in
                                devicePanelWidth = clampedDeviceWidth(
                                    value.location.x - (dividerWidth / 2),
                                    availableWidth: availableWidth
                                )
                            }
                    )

                DeviceDetailPanel(
                    device: selectedDevice,
                    isScanningServices: isScanningServices
                )
                .frame(width: max(minDetailWidth, availableWidth - deviceWidth - dividerWidth))
            }
            .coordinateSpace(name: "ScannerSplitView")
        }
    }

    private func clampedDeviceWidth(for availableWidth: CGFloat) -> CGFloat {
        let preferredWidth = devicePanelWidth ?? max(minDeviceWidth, availableWidth - dividerWidth - defaultDetailWidth)
        return clampedDeviceWidth(preferredWidth, availableWidth: availableWidth)
    }

    private func clampedDeviceWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maxDeviceWidth = max(minDeviceWidth, availableWidth - dividerWidth - minDetailWidth)
        return min(max(width, minDeviceWidth), maxDeviceWidth)
    }
}

struct SplitDivider: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)

            Capsule()
                .fill(AppColors.fieldBorder)
                .frame(width: 4)
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

struct DeviceListPanel: View {
    let devices: [NetworkDevice]
    let selectedDevice: NetworkDevice?
    let onSelect: (NetworkDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Devices")
                    .font(.caption)
                    .fontWeight(.bold)
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.caption)

                Spacer()

                PillLabel("\(devices.count) devices", isActive: false)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(devices) { device in
                        DeviceRow(device: device, isSelected: selectedDevice?.id == device.id)
                            .onTapGesture {
                                onSelect(device)
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .background(AppColors.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DeviceRow: View {
    let device: NetworkDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.treeDisclosure)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(device.displayName)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AppColors.heading : AppColors.topicName)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(device.ipAddress)
                    if let mac = device.macAddress {
                        Text(mac)
                    }
                    if let responseTime = device.responseTimeMS {
                        Text("\(Int(responseTime.rounded())) ms")
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppColors.badgeText)
                .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(isSelected ? AppColors.selectionBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct DeviceDetailPanel: View {
    let device: NetworkDevice?
    let isScanningServices: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Details")
                    .font(.caption)
                    .fontWeight(.bold)
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.caption)

                Spacer()
            }

            if let device {
                DetailField(label: "Name", value: device.displayName)
                DetailField(label: "IP Address", value: device.ipAddress)
                DetailField(label: "MAC Address", value: device.macAddress ?? "-")
                DetailField(label: "Vendor", value: device.vendor ?? "-")
                DetailField(label: "Last Seen", value: DateFormatter.scanner.string(from: device.lastSeen))

                Text("Services")
                    .font(.caption)
                    .fontWeight(.bold)
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.caption)

                if isScanningServices {
                    Text("Checking services...")
                        .foregroundStyle(AppColors.badgeText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppColors.readOnlyBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if detailPills(for: device).isEmpty {
                    Text("No common services detected")
                        .foregroundStyle(AppColors.badgeText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppColors.readOnlyBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    FlowPillRow(spacing: 8, rowSpacing: 8) {
                        ForEach(detailPills(for: device)) { pill in
                            IconPillLabel(pill.text, systemImage: pill.systemImage)
                        }
                    }
                }
            } else {
                Spacer()
                Text("Run a scan or select a device.")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.badgeText)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }

            Spacer()
        }
        .padding(18)
        .background(AppColors.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func detailPills(for device: NetworkDevice) -> [DetailPill] {
        device.services.map { service in
            DetailPill(text: "\(service.name) \(service.port)", systemImage: service.systemImage)
        }
    }
}

struct DetailPill: Identifiable, Hashable {
    let text: String
    let systemImage: String

    var id: String { "\(systemImage)-\(text)" }
}

struct FlowPillRow: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { total, row in
            total + row.height
        } + CGFloat(max(0, rows.count - 1)) * rowSpacing

        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [FlowRow] {
        var rows: [FlowRow] = []
        var current = FlowRow()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let candidateWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width

            if candidateWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = FlowRow()
            }

            current.indices.append(index)
            current.width = current.width == 0 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.indices.isEmpty {
            rows.append(current)
        }

        return rows
    }
}

private struct FlowRow {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
}

struct DetailField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .fontWeight(.bold)
                .textCase(.uppercase)
                .foregroundStyle(AppColors.caption)

            Text(value)
                .font(.system(size: 13, weight: .medium, design: label.contains("Address") ? .monospaced : .default))
                .foregroundStyle(AppColors.heading)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(AppColors.readOnlyBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AppColors.readOnlyBorder)
                }
        }
    }
}

struct StatusBar: View {
    let status: ScanStatus
    let deviceCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbolName)
                .foregroundStyle(statusTint)
            Text(status.text)
                .foregroundStyle(statusTint)

            Spacer()

            Text(deviceCount == 1 ? "1 device" : "\(deviceCount) devices")
                .foregroundStyle(AppColors.badgeText)
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(height: 40)
        .padding(.horizontal, 14)
        .background(AppColors.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusTint: Color {
        switch status {
        case .idle, .scanning:
            return AppColors.badgeText
        case .complete:
            return AppColors.primaryStrong
        case .failed:
            return AppColors.danger
        }
    }
}

struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.badgeText)

            TextField("Filter devices", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.heading)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColors.badgeText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(AppColors.inputBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(AppColors.fieldBorder)
        }
    }
}

struct PillLabel: View {
    let text: String
    var isActive = true

    init(_ text: String, isActive: Bool = true) {
        self.text = text
        self.isActive = isActive
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .foregroundStyle(isActive ? AppColors.primaryStrong : AppColors.badgeText)
            .background(isActive ? AppColors.badgeBackground : AppColors.neutralBadgeBackground)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(isActive ? AppColors.primary.opacity(0.65) : AppColors.fieldBorder, lineWidth: 1)
            }
            .contentShape(Capsule())
    }
}

struct IconPillLabel: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))

            Text(text)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .foregroundStyle(AppColors.primaryStrong)
        .background(AppColors.badgeBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(AppColors.primary.opacity(0.65), lineWidth: 1)
        }
        .contentShape(Capsule())
    }
}

enum AppColors {
    private static var theme: AppTheme {
        AppTheme.surface(SettingsStore.loadSurfaceTheme())
    }

    static var pageBackground: Color { theme.pageBackground }
    static var panelBackground: Color { theme.panelBackground }
    static var inputBackground: Color { theme.inputBackground }
    static var fieldBorder: Color { theme.softBorder }
    static let caption = adaptive(light: nsColor(0.44, 0.46, 0.49), dark: nsColor(0.66, 0.71, 0.69))
    static let heading = adaptive(light: nsColor(0.13, 0.16, 0.24), dark: nsColor(0.93, 0.96, 0.94))
    static let topicName = adaptive(light: nsColor(0.36, 0.38, 0.42), dark: nsColor(0.80, 0.84, 0.82))
    static let treeDisclosure = adaptive(light: nsColor(0.54, 0.58, 0.64), dark: nsColor(0.61, 0.68, 0.65))
    static let badgeText = adaptive(light: nsColor(0.35, 0.38, 0.46), dark: nsColor(0.72, 0.78, 0.75))
    static var primary: Color { theme.primary }
    static var primaryStrong: Color { theme.primaryStrong }
    static var badgeBackground: Color { theme.softBackground }
    static var neutralBadgeBackground: Color { theme.neutralBackground }
    static var previewBackground: Color { theme.previewBackground }
    static var previewText: Color { theme.previewText }
    static let danger = adaptive(light: nsColor(0.86, 0.20, 0.18), dark: nsColor(1.00, 0.38, 0.34))
    static var selectionBackground: Color { theme.softBackground }
    static var readOnlyBackground: Color { theme.previewBackground }
    static var readOnlyBorder: Color { theme.softBorder }

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func nsColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}

struct AppTheme {
    let pageBackground: Color
    let panelBackground: Color
    let inputBackground: Color
    let primary: Color
    let primaryStrong: Color
    let softBackground: Color
    let softBorder: Color
    let neutralBackground: Color
    let previewBackground: Color
    let previewText: Color

    static func surface(_ surface: AppSurfaceTheme) -> AppTheme {
        switch surface {
        case .hard:
            return AppTheme(
                pageBackground: AppColors.adaptive(light: AppColors.nsColor(0.33, 0.51, 0.69), dark: AppColors.nsColor(0.08, 0.12, 0.16)),
                panelBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.11, 0.15, 0.19)),
                inputBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.09, 0.14, 0.18)),
                primary: AppColors.adaptive(light: AppColors.nsColor(0.33, 0.51, 0.69), dark: AppColors.nsColor(0.44, 0.58, 0.73)),
                primaryStrong: AppColors.adaptive(light: AppColors.nsColor(0.13, 0.20, 0.27), dark: AppColors.nsColor(0.85, 0.90, 0.95)),
                softBackground: AppColors.adaptive(light: AppColors.nsColor(0.78, 0.86, 0.92), dark: AppColors.nsColor(0.09, 0.16, 0.22)),
                softBorder: AppColors.adaptive(light: AppColors.nsColor(0.52, 0.68, 0.81), dark: AppColors.nsColor(0.26, 0.42, 0.57)),
                neutralBackground: AppColors.adaptive(light: AppColors.nsColor(0.88, 0.93, 0.96), dark: AppColors.nsColor(0.14, 0.18, 0.22)),
                previewBackground: AppColors.adaptive(light: AppColors.nsColor(0.84, 0.91, 0.96), dark: AppColors.nsColor(0.09, 0.17, 0.24)),
                previewText: AppColors.adaptive(light: AppColors.nsColor(0.13, 0.30, 0.47), dark: AppColors.nsColor(0.57, 0.75, 0.91))
            )
        case .grass:
            return AppTheme(
                pageBackground: AppColors.adaptive(light: AppColors.nsColor(0.28, 0.62, 0.46), dark: AppColors.nsColor(0.08, 0.13, 0.12)),
                panelBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.11, 0.16, 0.14)),
                inputBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.09, 0.14, 0.12)),
                primary: AppColors.adaptive(light: AppColors.nsColor(0.18, 0.74, 0.51), dark: AppColors.nsColor(0.25, 0.80, 0.57)),
                primaryStrong: AppColors.adaptive(light: AppColors.nsColor(0.08, 0.52, 0.36), dark: AppColors.nsColor(0.46, 0.88, 0.68)),
                softBackground: AppColors.adaptive(light: AppColors.nsColor(0.78, 0.92, 0.85), dark: AppColors.nsColor(0.08, 0.22, 0.17)),
                softBorder: AppColors.adaptive(light: AppColors.nsColor(0.46, 0.78, 0.65), dark: AppColors.nsColor(0.18, 0.56, 0.40)),
                neutralBackground: AppColors.adaptive(light: AppColors.nsColor(0.89, 0.95, 0.91), dark: AppColors.nsColor(0.14, 0.19, 0.17)),
                previewBackground: AppColors.adaptive(light: AppColors.nsColor(0.82, 0.94, 0.88), dark: AppColors.nsColor(0.07, 0.23, 0.17)),
                previewText: AppColors.adaptive(light: AppColors.nsColor(0.02, 0.48, 0.34), dark: AppColors.nsColor(0.36, 0.88, 0.62))
            )
        case .clay:
            return AppTheme(
                pageBackground: AppColors.adaptive(light: AppColors.nsColor(0.58, 0.31, 0.24), dark: AppColors.nsColor(0.16, 0.10, 0.08)),
                panelBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.17, 0.12, 0.10)),
                inputBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.15, 0.10, 0.09)),
                primary: AppColors.adaptive(light: AppColors.nsColor(0.85, 0.42, 0.28), dark: AppColors.nsColor(0.89, 0.54, 0.41)),
                primaryStrong: AppColors.adaptive(light: AppColors.nsColor(0.44, 0.20, 0.16), dark: AppColors.nsColor(0.99, 0.80, 0.72)),
                softBackground: AppColors.adaptive(light: AppColors.nsColor(0.96, 0.84, 0.78), dark: AppColors.nsColor(0.23, 0.13, 0.10)),
                softBorder: AppColors.adaptive(light: AppColors.nsColor(0.86, 0.58, 0.47), dark: AppColors.nsColor(0.62, 0.31, 0.24)),
                neutralBackground: AppColors.adaptive(light: AppColors.nsColor(0.96, 0.90, 0.86), dark: AppColors.nsColor(0.22, 0.16, 0.14)),
                previewBackground: AppColors.adaptive(light: AppColors.nsColor(0.98, 0.88, 0.83), dark: AppColors.nsColor(0.24, 0.14, 0.11)),
                previewText: AppColors.adaptive(light: AppColors.nsColor(0.58, 0.24, 0.16), dark: AppColors.nsColor(0.94, 0.60, 0.46))
            )
        }
    }
}

extension DateFormatter {
    static let scanner: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
