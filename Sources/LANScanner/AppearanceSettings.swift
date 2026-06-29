import AppKit
import SwiftUI

enum AppAppearanceMode: String {
    case system
    case light
    case dark

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum AppSurfaceTheme: String, Identifiable {
    case hard
    case grass
    case clay

    static let cycle: [AppSurfaceTheme] = [.hard, .grass, .clay]
    static let pickerOrder: [AppSurfaceTheme] = [.clay, .grass, .hard]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clay:
            return "Roland Garros"
        case .grass:
            return "Wimbledon"
        case .hard:
            return "US Open"
        }
    }
}

final class AppearanceSettings: ObservableObject {
    @Published var mode: AppAppearanceMode = .system

    @Published var surface: AppSurfaceTheme {
        didSet {
            SettingsStore.save(surfaceTheme: surface)
        }
    }

    init(surface: AppSurfaceTheme = SettingsStore.loadSurfaceTheme()) {
        self.surface = surface
    }

    var preferredColorScheme: ColorScheme? {
        mode.preferredColorScheme
    }

    func toggle(over colorScheme: ColorScheme) {
        switch mode {
        case .system:
            mode = colorScheme == .dark ? .light : .dark
        case .light:
            mode = .dark
        case .dark:
            mode = .light
        }
    }

    func cycleSurface() {
        guard let index = AppSurfaceTheme.cycle.firstIndex(of: surface) else {
            surface = .hard
            return
        }

        surface = AppSurfaceTheme.cycle[(index + 1) % AppSurfaceTheme.cycle.count]
    }
}

struct FunctionKeyShortcut: ViewModifier {
    let keyCode: UInt16
    let functionKey: Int
    let action: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else {
                    return
                }

                let functionKeyString = UnicodeScalar(functionKey).map(String.init)
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == keyCode || event.charactersIgnoringModifiers == functionKeyString {
                        action()
                        return nil
                    }

                    return event
                }
            }
            .onDisappear {
                guard let monitor else {
                    return
                }

                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
    }
}

enum SettingsStore {
    private static let surfaceThemeKey = "ui.surfaceTheme"

    static func loadSurfaceTheme() -> AppSurfaceTheme {
        guard
            let rawValue = UserDefaults.standard.string(forKey: surfaceThemeKey),
            let surface = AppSurfaceTheme(rawValue: rawValue)
        else {
            return .grass
        }

        return surface
    }

    static func save(surfaceTheme: AppSurfaceTheme) {
        UserDefaults.standard.set(surfaceTheme.rawValue, forKey: surfaceThemeKey)
    }
}
