import SwiftUI

struct AppRootView: View {
    static let onboardingCompletedKey = "onboarding.completed"

    let processManager: TunnelProcessManager

    @State private var cloudflared = CloudflaredManager()
    @State private var didCheckSetup = false
    @AppStorage(AppRootView.onboardingCompletedKey) private var onboardingCompleted = false

    var body: some View {
        Group {
            if onboardingCompleted {
                ContentView(processManager: processManager)
            } else if didCheckSetup {
                SetupWizardView(cloudflared: cloudflared) { onboardingCompleted = true }
            } else {
                ProgressView()
                    .frame(minWidth: 620, minHeight: 520)
            }
        }
        .task {
            guard !onboardingCompleted else { return }
            await cloudflared.checkInstallation()
            // Existing setups (from before onboarding was tracked) skip it.
            if case .installed = cloudflared.status {
                onboardingCompleted = true
            } else if RelayManager.currentEnvironment() != nil {
                onboardingCompleted = true
            }
            didCheckSetup = true
        }
    }
}
