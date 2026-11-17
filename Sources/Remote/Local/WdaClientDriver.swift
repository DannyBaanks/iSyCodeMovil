import Foundation

/// Connects the local controller to the real WebDriverAgent client. The controller only knows the narrow
/// `WdaDriving` protocol; this adapter maps the client's own types onto it.
public struct WdaClientDriver: WdaDriving {
    private let client: WdaClient

    public init(client: WdaClient) {
        self.client = client
    }

    public func status() async throws -> LocalWdaStatus {
        let status = try await client.status()
        return LocalWdaStatus(
            ready: status.ready,
            locked: status.locked,
            foregroundBundleID: status.foregroundBundleID.isEmpty ? nil : status.foregroundBundleID,
            widthPoints: status.width,
            heightPoints: status.height
        )
    }

    public func screenshotPNG() async throws -> Data { try await client.screenshotPNG() }
    public func pageSource() async throws -> String { try await client.pageSource() }
    public func tap(x: Double, y: Double) async throws { try await client.tap(x: x, y: y) }

    public func longPress(x: Double, y: Double, seconds: Double) async throws {
        try await client.longPress(x: x, y: y, seconds: seconds)
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, seconds: Double) async throws {
        try await client.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, seconds: seconds)
    }

    public func typeText(_ text: String, submit: Bool) async throws {
        try await client.typeText(text, submit: submit)
    }

    public func pressButton(_ button: String) async throws { try await client.pressButton(button) }
    public func launchApp(bundleID: String) async throws { try await client.launchApp(bundleID: bundleID) }
    public func terminateApp(bundleID: String) async throws { try await client.terminateApp(bundleID: bundleID) }
}
