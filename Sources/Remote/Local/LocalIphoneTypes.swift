import Foundation

/// What the local controller needs to know about the phone. The WDA client maps its own
/// status onto this, so the controller does not depend on the concrete client.
public struct LocalWdaStatus: Sendable, Equatable {
    public let ready: Bool
    public let locked: Bool
    public let foregroundBundleID: String?
    public let widthPoints: Double
    public let heightPoints: Double

    public init(ready: Bool, locked: Bool, foregroundBundleID: String?, widthPoints: Double, heightPoints: Double) {
        self.ready = ready
        self.locked = locked
        self.foregroundBundleID = foregroundBundleID
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }
}

/// An element of the screen as the controller sees it. Placeholder until the element parser
/// lands; the parser's own element type replaces it.
public struct LocalElement: Sendable, Equatable {
    public let text: String
    public let centerX: Double
    public let centerY: Double

    public init(text: String, centerX: Double, centerY: Double) {
        self.text = text
        self.centerX = centerX
        self.centerY = centerY
    }
}
