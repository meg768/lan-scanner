import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var store = ScannerStore()
    @State private var searchText = ""
    @State private var sortColumn: DeviceSortColumn = .name
    @State private var sortAscending = true
    @State private var isSettingsPresented = false

    var body: some View {
        VStack(spacing: 8) {
            HeaderPanel(
                network: store.localNetwork,
                isScanning: store.isScanning
            )

            DeviceListPanel(
                devices: filteredDevices,
                sortColumn: $sortColumn,
                sortAscending: $sortAscending
            )

            StatusBar(status: store.status, deviceCount: store.devices.count)
        }
        .id("\(appearance.mode.rawValue)-\(appearance.surface.rawValue)")
        .padding(8)
        .frame(minWidth: 1100, minHeight: 660)
        .background(AppColors.pageBackground)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter devices")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)

                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            ThemeSettingsDialog(selectedTheme: $appearance.surface)
        }
        .onAppear {
            store.startAutoScan()
        }
        .onDisappear {
            store.stopAutoScan()
        }
        .modifier(FunctionKeyShortcut(keyCode: 97, functionKey: NSF6FunctionKey) {
            appearance.toggle(over: colorScheme)
        })
        .modifier(FunctionKeyShortcut(keyCode: 99, functionKey: NSF3FunctionKey) {
            appearance.cycleSurface()
        })
    }

    private var filteredDevices: [NetworkDevice] {
        let filtered = store.devices.filter { device in
            guard !searchText.isEmpty else {
                return true
            }

            let haystack = [
                device.ipAddress,
                device.hostname,
                device.dnsName,
                device.macAddress,
                device.vendor
            ]
                .compactMap { $0 }
                .joined(separator: " ")

            return haystack.localizedCaseInsensitiveContains(searchText)
        }

        return filtered.sorted { lhs, rhs in
            DeviceSortComparator.compare(lhs, rhs, by: sortColumn, ascending: sortAscending)
        }
    }
}

enum DeviceSortColumn {
    case name
    case address
    case vendor
    case ping
    case lastSeen

    var title: String {
        switch self {
        case .name:
            return "Name"
        case .address:
            return "Address"
        case .vendor:
            return "Vendor"
        case .ping:
            return "Ping"
        case .lastSeen:
            return "Seen"
        }
    }
}

enum DeviceSortComparator {
    static func compare(_ lhs: NetworkDevice, _ rhs: NetworkDevice, by column: DeviceSortColumn, ascending: Bool) -> Bool {
        let result: ComparisonResult

        switch column {
        case .name:
            result = compareText(lhs.displayName, rhs.displayName)
        case .address:
            result = compareText(lhs.tableIPSortKey, rhs.tableIPSortKey)
        case .vendor:
            result = compareText(lhs.tableVendor, rhs.tableVendor)
        case .ping:
            result = compareOptionalDouble(lhs.responseTimeMS, rhs.responseTimeMS)
        case .lastSeen:
            result = compareDate(lhs.lastSeen, rhs.lastSeen)
        }

        if result == .orderedSame {
            return lhs.tableIPSortKey < rhs.tableIPSortKey
        }

        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private static func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true):
            return .orderedSame
        case (true, false):
            return .orderedDescending
        case (false, true):
            return .orderedAscending
        case (false, false):
            return lhs.localizedStandardCompare(rhs)
        }
    }

    private static func compareOptionalDouble(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case (let lhs?, let rhs?):
            if lhs == rhs {
                return .orderedSame
            }

            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }

    private static func compareDate(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs == rhs {
            return .orderedSame
        }

        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

@MainActor
final class ScannerStore: ObservableObject {
    @Published var devices: [NetworkDevice] = []
    @Published var localNetwork = LANScanner.localNetwork()
    @Published var status: ScanStatus = .idle
    @Published var isScanning = false
    @Published var isBusy = false

    private let scanner = LANScanner()
    private var autoScanTask: Task<Void, Never>?
    private let autoScanInterval: UInt64 = 120_000_000_000

    func refreshLocalNetwork() {
        localNetwork = LANScanner.localNetwork()
    }

    func scan() {
        Task {
            await scanOnce()
        }
    }

    func startAutoScan() {
        guard autoScanTask == nil else {
            return
        }

        refreshLocalNetwork()
        autoScanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                await self.scanOnce()
                try? await Task.sleep(nanoseconds: self.autoScanInterval)
            }
        }
    }

    func stopAutoScan() {
        autoScanTask?.cancel()
        autoScanTask = nil
    }

    private func scanOnce() async {
        guard !isBusy else {
            return
        }

        isBusy = true
        isScanning = true
        status = .scanning("Scanning local network...")
        refreshLocalNetwork()

        do {
            let foundDevices = try await scanner.scan { completed, total in
                Task { @MainActor in
                    self.status = .scanning("Scanned \(completed) of \(total) addresses...")
                }
            }

            mergeDevices(foundDevices)
            isScanning = false
            status = .complete("Updated \(foundDevices.count) devices. \(devices.count) listed.")
            isBusy = false
        } catch {
            status = .failed(error.localizedDescription)
            isScanning = false
            isBusy = false
        }
    }

    private func mergeDevices(_ incomingDevices: [NetworkDevice]) {
        var merged = Dictionary(uniqueKeysWithValues: devices.map { ($0.ipAddress, $0) })

        for incomingDevice in incomingDevices {
            if let currentDevice = merged[incomingDevice.ipAddress] {
                merged[incomingDevice.ipAddress] = mergedDevice(currentDevice, with: incomingDevice)
            } else {
                merged[incomingDevice.ipAddress] = incomingDevice
            }
        }

        devices = merged.values.sorted { $0.tableIPSortKey < $1.tableIPSortKey }
    }

    private func mergedDevice(_ currentDevice: NetworkDevice, with incomingDevice: NetworkDevice) -> NetworkDevice {
        var nextDevice = incomingDevice
        nextDevice.hostname = incomingDevice.hostname ?? currentDevice.hostname
        nextDevice.dnsName = incomingDevice.dnsName ?? currentDevice.dnsName
        nextDevice.macAddress = incomingDevice.macAddress ?? currentDevice.macAddress
        nextDevice.vendor = incomingDevice.vendor ?? currentDevice.vendor
        nextDevice.responseTimeMS = incomingDevice.responseTimeMS ?? currentDevice.responseTimeMS
        return nextDevice
    }
}

struct HeaderPanel: View {
    let network: LocalNetwork?
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ScannerLabel()

                        if isScanning {
                            PillLabel("Scanning...")
                        }
                    }

                    Text(network?.displayName ?? "No local IPv4 network")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppColors.heading)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 8) {
                    AppLogoIcon()
                        .frame(width: 34, height: 34)

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("LAN")
                            .font(.system(size: 23, weight: .bold))
                        Text("Scanner")
                            .font(.system(size: 23, weight: .bold))
                    }
                }
                .foregroundStyle(AppColors.primaryStrong)
            }
        }
        .padding(20)
        .background(AppColors.panelBackground)
        .panelChrome()
    }
}

struct ScannerLabel: View {
    var body: some View {
        Text("Network")
            .font(.system(size: 13, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(AppColors.caption)
    }
}

struct AppLogoIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(AppColors.primaryStrong)

            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppColors.panelBackground)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct DeviceListPanel: View {
    let devices: [NetworkDevice]
    @Binding var sortColumn: DeviceSortColumn
    @Binding var sortAscending: Bool
    @State private var selectedDeviceID: String?
    @State private var inspectedDevice: InspectedDevice?
    @State private var inspectingDevice: NetworkDevice?

    private let scanner = LANScanner()

    var body: some View {
        ZStack {
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

                DeviceTableHeader(sortColumn: $sortColumn, sortAscending: $sortAscending)
                    .padding(.trailing, DeviceTableColumns.scrollbarGutter)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                            DeviceTableRow(
                                device: device,
                                isSelected: selectedDeviceID == device.id,
                                isAlternate: index.isMultiple(of: 2),
                                onInfo: {
                                    selectedDeviceID = device.id
                                    inspect(device)
                                }
                            )
                            .onTapGesture {
                                selectedDeviceID = device.id
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }

            if let inspectingDevice {
                DeviceInspectingOverlay(device: inspectingDevice)
            }
        }
        .background(AppColors.panelBackground)
        .panelChrome()
        .sheet(item: $inspectedDevice) { inspectedDevice in
            DeviceInfoDialog(device: inspectedDevice.device, inspection: inspectedDevice.inspection)
        }
    }

    private func inspect(_ device: NetworkDevice) {
        guard inspectingDevice == nil else {
            return
        }

        inspectingDevice = device

        Task {
            let inspection = await scanner.inspect(device: device)
            inspectingDevice = nil
            inspectedDevice = InspectedDevice(device: device, inspection: inspection)
        }
    }

}

struct InspectedDevice: Identifiable {
    let device: NetworkDevice
    let inspection: DeviceInspection

    var id: String { device.id }
}

struct DeviceInspectingOverlay: View {
    let device: NetworkDevice

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)

            Text("Inspecting device...")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColors.heading)

            Text(device.displayName)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppColors.badgeText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 250)
        .background(AppColors.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppColors.panelBorder, lineWidth: 1)
        }
        .shadow(radius: 14)
    }
}

struct DeviceTableHeader: View {
    @Binding var sortColumn: DeviceSortColumn
    @Binding var sortAscending: Bool

    var body: some View {
        HStack(spacing: 6) {
            DeviceHeaderCell(column: .name, sortColumn: $sortColumn, sortAscending: $sortAscending)
                .frame(minWidth: DeviceTableColumns.nameMinWidth, maxWidth: .infinity, alignment: .leading)
            DeviceHeaderCell(column: .address, sortColumn: $sortColumn, sortAscending: $sortAscending)
                .frame(width: DeviceTableColumns.addressWidth, alignment: .leading)
            DeviceHeaderCell(column: .vendor, sortColumn: $sortColumn, sortAscending: $sortAscending)
                .frame(minWidth: DeviceTableColumns.vendorMinWidth, maxWidth: .infinity, alignment: .leading)
            DeviceHeaderCell(column: .ping, sortColumn: $sortColumn, sortAscending: $sortAscending)
                .frame(width: DeviceTableColumns.pingWidth, alignment: .leading)
            DeviceHeaderCell(column: .lastSeen, sortColumn: $sortColumn, sortAscending: $sortAscending)
                .frame(width: DeviceTableColumns.seenWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(AppColors.panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColors.panelBorder)
                .frame(height: 1)
        }
    }
}

enum DeviceTableColumns {
    static let scrollbarGutter: CGFloat = 16
    static let nameMinWidth: CGFloat = 250
    static let addressWidth: CGFloat = 350
    static let vendorMinWidth: CGFloat = 220
    static let pingWidth: CGFloat = 90
    static let seenWidth: CGFloat = 96
}

struct DeviceHeaderCell: View {
    let column: DeviceSortColumn
    @Binding var sortColumn: DeviceSortColumn
    @Binding var sortAscending: Bool

    var body: some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(column.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Image(systemName: sortIcon)
                        .font(.system(size: 9, weight: .bold))
                        .opacity(isActive ? 1 : 0.42)
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isActive ? AppColors.primaryStrong : AppColors.badgeText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(isActive ? AppColors.badgeBackground : AppColors.neutralBadgeBackground)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(isActive ? AppColors.primary.opacity(0.75) : AppColors.fieldBorder, lineWidth: 1)
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isActive: Bool {
        sortColumn == column
    }

    private var sortIcon: String {
        guard isActive else {
            return "arrow.up.arrow.down"
        }

        return sortAscending ? "chevron.up" : "chevron.down"
    }
}

struct DeviceTableRow: View {
    let device: NetworkDevice
    let isSelected: Bool
    let isAlternate: Bool
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            DeviceTableCell(isPrimary: true) {
                HStack(spacing: 9) {
                    Button(action: onInfo) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColors.badgeText)
                            .frame(width: 18, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Text(device.displayName)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: DeviceTableColumns.nameMinWidth, maxWidth: .infinity, alignment: .leading)

            DeviceTableCell(isMonospaced: true) { Text(device.addressText) }
                .frame(width: DeviceTableColumns.addressWidth, alignment: .leading)
            DeviceTableCell { Text(device.vendor ?? "-") }
                .frame(minWidth: DeviceTableColumns.vendorMinWidth, maxWidth: .infinity, alignment: .leading)
            DeviceTableCell(isMonospaced: true) { Text(device.pingText) }
                .frame(width: DeviceTableColumns.pingWidth, alignment: .leading)
            DeviceTableCell(isMonospaced: true) { Text(DateFormatter.scannerTime.string(from: device.lastSeen)) }
                .frame(width: DeviceTableColumns.seenWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isSelected {
            return AppColors.selectionBackground
        }

        return isAlternate ? AppColors.tableRowBackground : AppColors.tableAlternateRowBackground
    }
}

struct DeviceTableCell<Content: View>: View {
    var isPrimary = false
    var isMonospaced = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
                .font(.system(size: isPrimary ? 14 : 13, weight: isPrimary ? .semibold : .regular, design: isMonospaced ? .monospaced : .default))
                .foregroundStyle(isPrimary ? AppColors.heading : AppColors.topicName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeviceInfoDialog: View {
    @Environment(\.dismiss) private var dismiss
    let device: NetworkDevice
    let inspection: DeviceInspection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColors.primaryStrong)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Device Inspection")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppColors.heading)
                    Text(device.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.badgeText)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Findings")
                        .font(.caption)
                        .fontWeight(.bold)
                        .textCase(.uppercase)
                        .foregroundStyle(AppColors.caption)

                    Spacer()
                }

                ScrollView {
                    inspectionContent
                }
                .frame(maxHeight: 420)
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520, height: 560)
        .background(AppColors.panelBackground)
    }

    @ViewBuilder
    private var inspectionContent: some View {
        if inspection.hasFindings {
            VStack(spacing: 0) {
                ForEach(inspection.likelyTypes, id: \.self) { type in
                    DeviceInspectionResultRow(
                        title: type,
                        detail: "Likely device type",
                        systemImage: "sparkles"
                    )
                }

                ForEach(inspection.openServices) { service in
                    DeviceInspectionResultRow(
                        title: service.name,
                        detail: service.port.map { "Port \($0) - \(service.detail)" } ?? service.detail,
                        systemImage: service.systemImage
                    )
                }

                ForEach(inspection.systemFindings) { finding in
                    DeviceInspectionResultRow(
                        title: finding.name,
                        detail: finding.detail,
                        systemImage: finding.systemImage
                    )
                }

                ForEach(inspection.notes, id: \.self) { note in
                    DeviceInspectionResultRow(
                        title: "Note",
                        detail: note,
                        systemImage: "note.text"
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.panelBorder, lineWidth: 1)
            }
        } else {
            DeviceInspectionMessage(text: "No open known services found. Only local device data is available.", systemImage: "checkmark.circle")
        }
    }
}

struct ThemeSettingsDialog: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTheme: AppSurfaceTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(AppColors.primaryStrong)

                Text("Settings")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColors.heading)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Theme")
                    .font(.caption)
                    .fontWeight(.bold)
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.caption)

                VStack(spacing: 8) {
                    ForEach(AppSurfaceTheme.pickerOrder) { theme in
                        ThemeChoiceRow(
                            theme: theme,
                            isSelected: selectedTheme == theme
                        ) {
                            selectedTheme = theme
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(AppColors.panelBackground)
    }
}

struct ThemeChoiceRow: View {
    let theme: AppSurfaceTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ThemeSwatch(theme: theme)
                    .frame(width: 34, height: 24)

                Text(theme.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isSelected ? AppColors.primaryStrong : AppColors.heading)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? AppColors.primaryStrong : AppColors.badgeText)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isSelected ? AppColors.badgeBackground : AppColors.tableRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? AppColors.primary.opacity(0.65) : AppColors.panelBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct ThemeSwatch: View {
    let theme: AppSurfaceTheme

    var body: some View {
        HStack(spacing: 0) {
            swatchColors.0
            swatchColors.1
            swatchColors.2
        }
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(AppColors.panelBorder, lineWidth: 1)
        }
    }

    private var swatchColors: (Color, Color, Color) {
        switch theme {
        case .clay:
            return (
                Color(nsColor: AppColors.nsColor(0.58, 0.31, 0.24)),
                Color(nsColor: AppColors.nsColor(0.85, 0.42, 0.28)),
                Color(nsColor: AppColors.nsColor(0.96, 0.84, 0.78))
            )
        case .grass:
            return (
                Color(nsColor: AppColors.nsColor(0.08, 0.52, 0.36)),
                Color(nsColor: AppColors.nsColor(0.18, 0.74, 0.51)),
                Color(nsColor: AppColors.nsColor(0.78, 0.92, 0.85))
            )
        case .hard:
            return (
                Color(nsColor: AppColors.nsColor(0.02, 0.19, 0.36)),
                Color(nsColor: AppColors.nsColor(0.08, 0.36, 0.62)),
                Color(nsColor: AppColors.nsColor(0.79, 0.88, 0.96))
            )
        }
    }
}

struct DeviceInspectionMessage: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(AppColors.badgeText)
        .padding(12)
        .background(AppColors.tableRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppColors.panelBorder, lineWidth: 1)
        }
    }
}

struct DeviceInspectionResultRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColors.primaryStrong)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppColors.heading)
                Text(detail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.badgeText)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppColors.tableRowBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColors.panelBorder)
                .frame(height: 1)
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
        .panelChrome()
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

extension View {
    func panelChrome() -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.panelBorder, lineWidth: 1)
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
    static var panelBorder: Color { theme.panelBorder }
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
    static var tableHeaderBackground: Color { theme.tableHeaderBackground }
    static var tableRowBackground: Color { theme.tableRowBackground }
    static var tableAlternateRowBackground: Color { theme.tableAlternateRowBackground }
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
    let panelBorder: Color
    let inputBackground: Color
    let primary: Color
    let primaryStrong: Color
    let softBackground: Color
    let softBorder: Color
    let neutralBackground: Color
    let tableHeaderBackground: Color
    let tableRowBackground: Color
    let tableAlternateRowBackground: Color
    let previewBackground: Color
    let previewText: Color

    static func surface(_ surface: AppSurfaceTheme) -> AppTheme {
        switch surface {
        case .hard:
            return AppTheme(
                pageBackground: AppColors.adaptive(light: AppColors.nsColor(0.42, 0.58, 0.72), dark: AppColors.nsColor(0.02, 0.07, 0.14)),
                panelBackground: AppColors.adaptive(light: AppColors.nsColor(0.98, 1.00, 1.00), dark: AppColors.nsColor(0.07, 0.11, 0.17)),
                panelBorder: AppColors.adaptive(light: AppColors.nsColor(0.83, 0.91, 0.98), dark: AppColors.nsColor(0.13, 0.24, 0.35)),
                inputBackground: AppColors.adaptive(light: AppColors.nsColor(0.99, 1.00, 1.00), dark: AppColors.nsColor(0.05, 0.10, 0.16)),
                primary: AppColors.adaptive(light: AppColors.nsColor(0.08, 0.36, 0.62), dark: AppColors.nsColor(0.35, 0.58, 0.86)),
                primaryStrong: AppColors.adaptive(light: AppColors.nsColor(0.02, 0.19, 0.36), dark: AppColors.nsColor(0.73, 0.86, 1.00)),
                softBackground: AppColors.adaptive(light: AppColors.nsColor(0.79, 0.88, 0.96), dark: AppColors.nsColor(0.05, 0.15, 0.25)),
                softBorder: AppColors.adaptive(light: AppColors.nsColor(0.42, 0.62, 0.82), dark: AppColors.nsColor(0.20, 0.42, 0.64)),
                neutralBackground: AppColors.adaptive(light: AppColors.nsColor(0.88, 0.93, 0.97), dark: AppColors.nsColor(0.10, 0.14, 0.20)),
                tableHeaderBackground: AppColors.adaptive(light: AppColors.nsColor(0.90, 0.95, 0.99), dark: AppColors.nsColor(0.08, 0.13, 0.20)),
                tableRowBackground: AppColors.adaptive(light: AppColors.nsColor(0.98, 1.00, 1.00), dark: AppColors.nsColor(0.07, 0.11, 0.17)),
                tableAlternateRowBackground: AppColors.adaptive(light: AppColors.nsColor(0.94, 0.98, 1.00), dark: AppColors.nsColor(0.09, 0.14, 0.21)),
                previewBackground: AppColors.adaptive(light: AppColors.nsColor(0.83, 0.91, 0.98), dark: AppColors.nsColor(0.04, 0.14, 0.24)),
                previewText: AppColors.adaptive(light: AppColors.nsColor(0.04, 0.27, 0.48), dark: AppColors.nsColor(0.54, 0.76, 1.00))
            )
        case .grass:
            return AppTheme(
                pageBackground: AppColors.adaptive(light: AppColors.nsColor(0.28, 0.62, 0.46), dark: AppColors.nsColor(0.08, 0.13, 0.12)),
                panelBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.11, 0.16, 0.14)),
                panelBorder: AppColors.adaptive(light: AppColors.nsColor(0.82, 0.93, 0.87), dark: AppColors.nsColor(0.15, 0.28, 0.22)),
                inputBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.09, 0.14, 0.12)),
                primary: AppColors.adaptive(light: AppColors.nsColor(0.18, 0.74, 0.51), dark: AppColors.nsColor(0.25, 0.80, 0.57)),
                primaryStrong: AppColors.adaptive(light: AppColors.nsColor(0.08, 0.52, 0.36), dark: AppColors.nsColor(0.46, 0.88, 0.68)),
                softBackground: AppColors.adaptive(light: AppColors.nsColor(0.78, 0.92, 0.85), dark: AppColors.nsColor(0.08, 0.22, 0.17)),
                softBorder: AppColors.adaptive(light: AppColors.nsColor(0.46, 0.78, 0.65), dark: AppColors.nsColor(0.18, 0.56, 0.40)),
                neutralBackground: AppColors.adaptive(light: AppColors.nsColor(0.89, 0.95, 0.91), dark: AppColors.nsColor(0.14, 0.19, 0.17)),
                tableHeaderBackground: AppColors.adaptive(light: AppColors.nsColor(0.88, 0.96, 0.91), dark: AppColors.nsColor(0.12, 0.19, 0.16)),
                tableRowBackground: AppColors.adaptive(light: AppColors.nsColor(0.99, 1.00, 0.99), dark: AppColors.nsColor(0.10, 0.16, 0.14)),
                tableAlternateRowBackground: AppColors.adaptive(light: AppColors.nsColor(0.93, 0.98, 0.95), dark: AppColors.nsColor(0.13, 0.20, 0.17)),
                previewBackground: AppColors.adaptive(light: AppColors.nsColor(0.82, 0.94, 0.88), dark: AppColors.nsColor(0.07, 0.23, 0.17)),
                previewText: AppColors.adaptive(light: AppColors.nsColor(0.02, 0.48, 0.34), dark: AppColors.nsColor(0.36, 0.88, 0.62))
            )
        case .clay:
            return AppTheme(
                pageBackground: AppColors.adaptive(light: AppColors.nsColor(0.58, 0.31, 0.24), dark: AppColors.nsColor(0.16, 0.10, 0.08)),
                panelBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.17, 0.12, 0.10)),
                panelBorder: AppColors.adaptive(light: AppColors.nsColor(0.96, 0.84, 0.78), dark: AppColors.nsColor(0.28, 0.18, 0.15)),
                inputBackground: AppColors.adaptive(light: AppColors.nsColor(1, 1, 1), dark: AppColors.nsColor(0.15, 0.10, 0.09)),
                primary: AppColors.adaptive(light: AppColors.nsColor(0.85, 0.42, 0.28), dark: AppColors.nsColor(0.89, 0.54, 0.41)),
                primaryStrong: AppColors.adaptive(light: AppColors.nsColor(0.44, 0.20, 0.16), dark: AppColors.nsColor(0.99, 0.80, 0.72)),
                softBackground: AppColors.adaptive(light: AppColors.nsColor(0.96, 0.84, 0.78), dark: AppColors.nsColor(0.23, 0.13, 0.10)),
                softBorder: AppColors.adaptive(light: AppColors.nsColor(0.86, 0.58, 0.47), dark: AppColors.nsColor(0.62, 0.31, 0.24)),
                neutralBackground: AppColors.adaptive(light: AppColors.nsColor(0.96, 0.90, 0.86), dark: AppColors.nsColor(0.22, 0.16, 0.14)),
                tableHeaderBackground: AppColors.adaptive(light: AppColors.nsColor(0.98, 0.90, 0.86), dark: AppColors.nsColor(0.20, 0.13, 0.11)),
                tableRowBackground: AppColors.adaptive(light: AppColors.nsColor(1.00, 0.99, 0.98), dark: AppColors.nsColor(0.17, 0.12, 0.10)),
                tableAlternateRowBackground: AppColors.adaptive(light: AppColors.nsColor(0.98, 0.93, 0.90), dark: AppColors.nsColor(0.22, 0.15, 0.12)),
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

    static let scannerTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
