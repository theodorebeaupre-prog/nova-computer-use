import AppKit
import SwiftUI
import NovaInstallerCore

@main
struct NovaApplication: App {
    @StateObject private var model = NovaAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)
    }
}

@MainActor
final class NovaAppModel: ObservableObject {
    enum Phase { case welcome, setup, dashboard }

    @Published var phase: Phase = .welcome
    @Published var report = NovaInspector.inspectCurrentSystem()
    @Published var isWorking = false
    @Published var message: String?
    @Published var technicalDetails: String?

    private var resources: NovaResources {
        NovaResources(root: Bundle.main.resourceURL ?? URL(fileURLWithPath: "/"))
    }

    func refresh() {
        report = NovaInspector.inspectCurrentSystem()
        if report.healthy { phase = .dashboard }
    }

    func install() { run(operation: "Installation terminée.") { try await NovaInstaller(resources: self.resources).install() } }
    func repair() { run(operation: "Nova a été réparé.") { try await NovaInstaller(resources: self.resources).repair() } }
    func uninstall() { run(operation: "Nova a été désinstallé.") { try await NovaInstaller(resources: self.resources).uninstall() } }

    func openAccessibility() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecording() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func runSafeTest() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            Task { @MainActor in
                if let error {
                    self.message = "TextEdit n’a pas pu s’ouvrir."
                    self.technicalDetails = NovaDiagnostics.redact(error.localizedDescription)
                } else {
                    self.run(operation: "Nova voit correctement TextEdit. Le test de permissions est réussi.") {
                        try await NovaInstaller(resources: self.resources).probePermissions()
                    }
                }
            }
        }
    }

    private func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func run(operation success: String, action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        technicalDetails = nil
        Task {
            do {
                try await action()
                refresh()
                message = success
            } catch {
                message = "Ça n’a pas fonctionné. Vérifie les détails, puis réessaie."
                technicalDetails = NovaDiagnostics.redact(error.localizedDescription)
            }
            isWorking = false
        }
    }
}
