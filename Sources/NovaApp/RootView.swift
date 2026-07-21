import SwiftUI
import NovaInstallerCore

struct RootView: View {
    @EnvironmentObject private var model: NovaAppModel

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.027, blue: 0.042).ignoresSafeArea()
            ambientGlow

            switch model.phase {
            case .welcome: WelcomeView()
            case .setup: SetupView()
            case .dashboard: DashboardView()
            }
        }
        .task { model.refresh() }
        .alert("Nova", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var ambientGlow: some View {
        RadialGradient(
            colors: [Color.purple.opacity(0.18), Color.cyan.opacity(0.06), .clear],
            center: .topTrailing,
            startRadius: 30,
            endRadius: 620
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: NovaAppModel

    var body: some View {
        VStack(spacing: 28) {
            NovaMark(size: 94)
            VStack(spacing: 10) {
                Text("NOVA")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .tracking(8)
                Text("Give Codex hands and eyes.")
                    .font(.title2.weight(.medium))
                Text("Installe et configure Computer Use sur ton Mac — sans Terminal.")
                    .foregroundStyle(.secondary)
            }
            Button("Commencer") { model.phase = .setup }
                .buttonStyle(NovaPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(64)
        .novaOrbit(cornerRadius: 32)
        .padding(54)
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: NovaAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                NovaMark(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Configuration de Nova").font(.largeTitle.bold())
                    Text("On vérifie ton Mac avant d’installer quoi que ce soit.").foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 16) {
                StatusCard(title: "macOS 15+", detail: "Système compatible", okay: model.report.macOSSupported)
                StatusCard(title: model.report.architecture, detail: "Intel + Apple Silicon", okay: model.report.architectureSupported)
                StatusCard(title: "Codex", detail: model.report.codexAvailable ? "Détecté" : "Introuvable", okay: model.report.codexAvailable)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Permissions macOS").font(.title3.bold())
                Text("macOS doit autoriser le helper Nova exact. Nova ouvre seulement les bons réglages; il ne contourne jamais tes permissions.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Ouvrir Accessibilité") { model.openAccessibility() }
                    Button("Ouvrir Enregistrement de l’écran") { model.openScreenRecording() }
                }
            }

            Spacer()
            HStack {
                Button("Retour") { model.phase = .welcome }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button(model.report.pluginInstalled ? "Réinstaller Nova" : "Installer Nova") { model.install() }
                    .buttonStyle(NovaPrimaryButtonStyle())
                    .disabled(model.isWorking || !model.report.readyForInstallation)
            }
        }
        .padding(42)
        .novaOrbit(cornerRadius: 28)
        .padding(36)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: NovaAppModel

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 22) {
                HStack { NovaMark(size: 48); Text("NOVA").font(.title.bold()).tracking(5) }
                Text("Computer Use est installé.").font(.largeTitle.bold())
                Text("Nova garde le plugin Codex en santé et te guide quand macOS redemande une permission.")
                    .foregroundStyle(.secondary)
                HealthRow(label: "Système compatible", okay: model.report.macOSSupported)
                HealthRow(label: "Codex détecté", okay: model.report.codexAvailable)
                HealthRow(label: "Plugin installé", okay: model.report.pluginInstalled)
                HealthRow(label: "Plugin activé", okay: model.report.pluginEnabled)
                Spacer()
                Text("Les contrôles restent locaux sur ton Mac. Nova ne fait aucun relais cloud.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                Text("Actions").font(.title2.bold())
                ActionButton(title: "Tester avec TextEdit", subtitle: "Ouvre un document non sensible", icon: "checkmark.shield") { model.runSafeTest() }
                ActionButton(title: "Réparer l’installation", subtitle: "Réinstalle les fichiers Nova", icon: "wrench.and.screwdriver") { model.repair() }
                ActionButton(title: "Permissions", subtitle: "Ouvre les réglages macOS", icon: "hand.raised") { model.openAccessibility() }
                ActionButton(title: "Actualiser", subtitle: "Revérifie Codex et le plugin", icon: "arrow.clockwise") { model.refresh() }
                Divider().padding(.vertical, 6)
                Button("Désinstaller Nova", role: .destructive) { model.uninstall() }
                    .disabled(model.isWorking)
                if let details = model.technicalDetails {
                    DisclosureGroup("Détails techniques") { Text(details).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Spacer()
            }
            .padding(24)
            .frame(width: 330)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(42)
        .novaOrbit(cornerRadius: 28)
        .padding(36)
    }
}

private struct StatusCard: View {
    let title: String
    let detail: String
    let okay: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: okay ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(okay ? .green : .orange)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct HealthRow: View {
    let label: String
    let okay: Bool
    var body: some View {
        Label(label, systemImage: okay ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(okay ? .green : .red)
            .accessibilityLabel("\(label): \(okay ? "OK" : "à corriger")")
    }
}

private struct ActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 26)
                VStack(alignment: .leading) { Text(title).fontWeight(.semibold); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct NovaMark: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(AngularGradient(colors: [.cyan, .purple, .pink, .orange, .cyan], center: .center), lineWidth: max(3, size * 0.055))
            Circle().fill(.white.opacity(0.92)).frame(width: size * 0.18)
        }
        .frame(width: size, height: size)
        .shadow(color: .purple.opacity(0.5), radius: 16)
        .accessibilityHidden(true)
    }
}

struct NovaPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background(.white.opacity(configuration.isPressed ? 0.72 : 0.94), in: Capsule())
            .foregroundStyle(.black)
    }
}
