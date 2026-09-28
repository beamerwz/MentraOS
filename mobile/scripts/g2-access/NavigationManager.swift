import CoreLocation
import Foundation

/// Navigation is intentionally disabled in the G2 accessibility build.
/// This keeps Mentra's glasses/BLE/audio/STT stack intact while avoiding
/// Mapbox's private Downloads-token requirement on our unsigned CI build.
@MainActor
final class NavigationManager: NSObject {
    static let shared = NavigationManager()

    typealias EventCallback = ([String: Any]) -> Void
    typealias LocationCallback = ([String: Any]) -> Void
    typealias RouteCallback = ([String: Any]) -> Void
    typealias StartCompletion = (Bool, String?) -> Void

    func requestPermission(completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func start(
        stops: [(lat: Double, lng: Double)],
        mode: String,
        simulate: Bool,
        speedMultiplier: Double,
        missedTurnRerouteMeters: Double? = nil,
        onEvent: @escaping EventCallback,
        onLocation: @escaping LocationCallback,
        onRoute: @escaping RouteCallback,
        completion: @escaping StartCompletion
    ) {
        _ = (stops, mode, simulate, speedMultiplier, missedTurnRerouteMeters)
        _ = (onEvent, onLocation, onRoute)
        completion(false, "Phone navigation is disabled in this G2 accessibility build")
    }

    func stop() {}

    func simulateDeviation(offsetMeters: Double) {
        _ = offsetMeters
    }
}
