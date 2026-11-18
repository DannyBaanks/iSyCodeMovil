import SwiftUI
import WebKit

/// In-app browser view with address bar, progress indicator, and "Take over" banner when the agent is driving it.
public struct InAppBrowserView: View {
    @ObservedObject private var browser = InAppBrowserService.shared
    @State private var urlDraft = ""
    @FocusState private var isAddressFocused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if browser.isAgentControlled {
                agentControlBanner
            }

            addressBar

            if browser.isLoading {
                ProgressView(value: browser.estimatedProgress)
                    .tint(IysThemePreferences.active.accent)
            }

            WebViewContainer(webView: browser.webView)
                .allowsHitTesting(!browser.isAgentControlled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle(browser.pageTitle?.isEmpty == false ? (browser.pageTitle ?? "Navegador") : "Navegador")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if urlDraft.isEmpty, let url = browser.currentURL, url.absoluteString != "about:blank" {
                urlDraft = url.absoluteString
            }
        }
        .onChange(of: browser.currentURL) { newURL in
            if !isAddressFocused, let newURL, newURL.absoluteString != "about:blank" {
                urlDraft = newURL.absoluteString
            }
        }
    }

    private var agentControlBanner: some View {
        HStack(spacing: OCSpacing.sm) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("El asistente está usando el navegador")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Button("Tomar control") {
                browser.releaseAgentControl()
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.22))
            .clipShape(Capsule())
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.vertical, 8)
        .background(IysThemePreferences.active.accent)
    }

    private var addressBar: some View {
        HStack(spacing: OCSpacing.sm) {
            TextField("Escribe una dirección web…", text: $urlDraft)
                .focused($isAddressFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit {
                    isAddressFocused = false
                    Task { _ = await browser.navigate(to: urlDraft, byAgent: false) }
                }
                .font(.system(size: 14))
                .foregroundColor(OCColor.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(OCColor.bgLayer1)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r12))
                .overlay(RoundedRectangle(cornerRadius: OCRadius.r12).stroke(OCColor.borderMuted, lineWidth: 1))

            if !urlDraft.isEmpty {
                Button {
                    isAddressFocused = false
                    Task { _ = await browser.navigate(to: urlDraft, byAgent: false) }
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(IysThemePreferences.active.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ir a la dirección")
            }
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.vertical, OCSpacing.sm)
        .background(OCColor.bgBase)
    }

    private var bottomBar: some View {
        HStack(spacing: OCSpacing.xl) {
            Button { Task { await browser.goBack() } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .accessibilityLabel("Atrás")

            Button { Task { await browser.goForward() } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .accessibilityLabel("Adelante")

            Spacer()

            Button { Task { await browser.reload() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Recargar")

            Button {
                browser.closeAllPages()
                urlDraft = ""
            } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel("Cerrar página")
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundColor(OCColor.iconPrimary)
        .padding(.horizontal, OCSpacing.xl)
        .padding(.vertical, OCSpacing.sm)
        .background(OCColor.bgBase)
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
