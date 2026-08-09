import CoreGraphics
import Foundation

public struct SetupWindowPlacement {
    public static let defaultStorageKey = "mimi.setupWindowPlacement"

    private let storageKey: String
    private let defaults: UserDefaults

    public init(storageKey: String = Self.defaultStorageKey, defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
    }

    public func savedOrigin() -> CGPoint? {
        guard let data = defaults.data(forKey: storageKey),
              let point = try? JSONDecoder().decode(StoredOrigin.self, from: data)
        else {
            return nil
        }
        return CGPoint(x: point.x, y: point.y)
    }

    public func save(origin: CGPoint) {
        let point = StoredOrigin(x: round(origin.x), y: round(origin.y))
        guard let data = try? JSONEncoder().encode(point) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    public func preferredOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let origin = savedOrigin() ?? Self.defaultOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
        return Self.clamped(origin: origin, windowSize: windowSize, visibleFrame: visibleFrame)
    }

    public static func defaultOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.minX + max(24, floor((visibleFrame.width - windowSize.width) / 2)),
            y: visibleFrame.maxY - windowSize.height - 72
        )
    }

    public static func clamped(origin: CGPoint, windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - windowSize.width - 8
        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - windowSize.height - 8

        return CGPoint(
            x: min(max(origin.x, minX), max(minX, maxX)),
            y: min(max(origin.y, minY), max(minY, maxY))
        )
    }
}

private struct StoredOrigin: Codable {
    let x: CGFloat
    let y: CGFloat
}
