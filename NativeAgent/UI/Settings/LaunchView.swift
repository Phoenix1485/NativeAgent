import SwiftUI

struct LaunchView: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var settings: AppPreferences
    var body: some View {
        WorkspaceView().environmentObject(model)
            .accentColor(settings.accent.color).tint(settings.accent.color)
            .preferredColorScheme(settings.theme.scheme)
            .sheet(isPresented: Binding(get: { !settings.onboardingComplete }, set: { _ in })) {
                SettingsHub(model: model, settings: settings, onboarding: true)
                    .frame(width: 940, height: 690).interactiveDismissDisabled()
            }
    }
}
