import SwiftUI
import UIKit
import UserNotifications
import IysCodeMovilCore

@MainActor
final class GUSBackgroundDownloadAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PermissionNotifier.shared.registerCategory()
        return true
    }

    /// Show assistant and daemon alerts even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Tapping an assistant alert opens the Asistente.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let requestID = userInfo[PermissionNotifier.requestKey] as? String,
           let decision = PermissionNotifier.decision(forAction: response.actionIdentifier) {
            Task { @MainActor in PermissionNotifier.shared.deliver(requestID: requestID, decision: decision) }
        }
        if response.notification.request.content.userInfo["open"] as? String == "assistant" {
            UserDefaults.standard.set(true, forKey: AssistantLaunch.openKey)
            DispatchQueue.main.async { AssistantLaunch.open() }
        }
        completionHandler()
    }

    func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
       completionHandler: @escaping () -> Void) {
        GUSModelDownloadManager.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }
}

@main
public struct IysCodeMovilApp: App {
    @UIApplicationDelegateAdaptor(GUSBackgroundDownloadAppDelegate.self) private var appDelegate
    @StateObject private var store = WorkbenchStore()
    @StateObject private var hostStore = MobileHostStore()
    @StateObject private var assistant = AssistantStore()
    @StateObject private var router = AppShellRouter()
    @AppStorage(IysAppearance.storageKey) private var appearance = IysAppearance.automatic.rawValue

    public init() {
        // First: diagnose how the previous run ended, before any model work.
        GUSFlightRecorder.shared.start()
        GUSMetricKitCollector.shared.register()
        IysThemePreferences.applyPendingOnLaunch()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(hostStore)
                .environmentObject(store.sessionState)
                .environmentObject(assistant)
                .environmentObject(router)
                .preferredColorScheme(IysAppearance(rawValue: appearance)?.colorScheme)
                .tint(IysThemePreferences.active.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OCColor.bgDeep.ignoresSafeArea())
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var hostStore: MobileHostStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var router: AppShellRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var enteredBackground = false
    @State private var forceOnboardingPreview = false

    var body: some View {
        rootContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .task {
            #if targetEnvironment(simulator)
            if let screenshotArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--readme-screenshot=") }) {
                let scene = String(screenshotArgument.dropFirst("--readme-screenshot=".count))
                switch scene {
                case "connect":
                    forceOnboardingPreview = true
                case "projects":
                    store.prepareReadmeScreenshot("projects")
                    store.hasCompletedOnboarding = true
                    router.openProjects()
                case "chat":
                    store.prepareReadmeScreenshot("chat")
                    store.hasCompletedOnboarding = true
                    router.openConversations()
                case "assistant":
                    assistant.prepareReadmeScreenshot("assistant")
                    store.hasCompletedOnboarding = true
                    router.openHome()
                case "assistant-memory":
                    assistant.prepareReadmeScreenshot("assistant-memory")
                    store.hasCompletedOnboarding = true
                    router.openGoogle(subtab: .memory)
                default:
                    store.prepareReadmeScreenshot(scene)
                    store.hasCompletedOnboarding = true
                }
                return
            }
            #endif
            await store.restorePersistedExperience()
            // Already past the welcome screen: ask at launch (no-op once decided) so the
            // alert never appears in the middle of an agent turn.
            if store.hasCompletedOnboarding {
                await PermissionNotifier.shared.prepare()
            }
            await hostStore.restore()
            await hostStore.setAppActive(scenePhase == .active)
            consumePendingAppIntent()
        }
        .onOpenURL { url in
            guard url.scheme == "iyscodemovil" else { return }
            if url.host == "native", url.path == "/sandbox" {
                store.hasCompletedOnboarding = true
                router.openHome()
                Task { await store.useNativeRuntime() }
            } else {
                store.offeredPairingLink = url.absoluteString
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AssistantLaunch.openNotification)) { _ in
            UserDefaults.standard.removeObject(forKey: AssistantLaunch.openKey)
            store.hasCompletedOnboarding = true
            router.openHome()
        }
        .sheet(isPresented: Binding(
            get: { store.offeredPairingLink != nil },
            set: { if !$0 { store.offeredPairingLink = nil } }
        )) {
            PairingConfirmSheet(link: store.offeredPairingLink ?? "")
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            Task { await hostStore.setAppActive(phase == .active) }
            if phase == .active {
                GUSFlightRecorder.shared.markForeground()
                consumePendingAppIntent()
                if UserDefaults.standard.bool(forKey: AssistantLaunch.openKey) {
                    UserDefaults.standard.removeObject(forKey: AssistantLaunch.openKey)
                    store.hasCompletedOnboarding = true
                    router.openHome()
                }
            }
            if phase == .background {
                GUSFlightRecorder.shared.markBackground()
                enteredBackground = true
            } else if phase == .active, enteredBackground {
                enteredBackground = false
                Task { await store.resumeRemoteSessionAfterBackground() }
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if forceOnboardingPreview || (!store.hasCompletedOnboarding && store.backendMode == .unconfigured && !store.isRestoringRuntime) {
            // The onboarding art is drawn for a dark background.
            ConnectionView()
                .environment(\.colorScheme, .dark)
        } else if store.isRestoringRuntime && !store.hasCompletedOnboarding {
            VStack(spacing: OCSpacing.lg) {
                ProgressView()
                    .tint(IysThemePreferences.active.accent)
                Text("Restaurando tu espacio de trabajo…")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OCColor.bgDeep.ignoresSafeArea())
        } else {
            AppShellView()
        }
    }

    private func consumePendingAppIntent() {
        guard UserDefaults.standard.bool(forKey: "native.openSandboxOnLaunch") else { return }
        UserDefaults.standard.removeObject(forKey: "native.openSandboxOnLaunch")
        store.hasCompletedOnboarding = true
        router.openHome()
        Task { await store.useNativeRuntime() }
    }
}
