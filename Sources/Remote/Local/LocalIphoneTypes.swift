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

/// A text-bearing element in WebDriverAgent's accessibility tree.
/// `name` is the accessibility identifier WDA returns and is printed as `id`.
public struct LocalElement: Sendable, Equatable {
    public let kind: String
    public let label: String
    public let name: String
    public let value: String
    public let centerX: Int
    public let centerY: Int
    public let width: Int
    public let height: Int

    public var id: String { name }

    /// The text shown first in the model-facing element description.
    public var text: String {
        [label, name, value].first(where: { !$0.isEmpty }) ?? ""
    }

    /// Rust's list filter searches the kind, label, name and value, including unclipped text.
    public var searchableText: String { [kind, label, name, value].joined(separator: " ") }

    /// Text that counts as visible content when waiting for a result. Typed field values are
    /// excluded, matching the WDA reader's `find_shown` behavior.
    var waitSearchTexts: [String] {
        if ["TextField", "SearchField", "TextView", "SecureTextField"].contains(kind) {
            return [label, name].filter { !$0.isEmpty && $0 != value }
        }
        return [label, name, value].filter { !$0.isEmpty }
    }

    public init(
        kind: String,
        label: String,
        name: String,
        value: String,
        centerX: Int,
        centerY: Int,
        width: Int,
        height: Int
    ) {
        self.kind = kind
        self.label = label
        self.name = name
        self.value = value
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }
}
