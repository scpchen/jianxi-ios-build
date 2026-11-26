import Foundation
import CoreLocation

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationFix, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var permitted: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func current() async throws -> LocationFix {
        guard permitted else { throw ClientError("付款前需要定位权限，用于确认设备所在位置") }
        if manager.accuracyAuthorization == .reducedAccuracy {
            try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "DeviceLocation")
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                self.finish(.failure(ClientError("定位超时，请到开阔处重试")))
            }
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<LocationFix, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else {
                self.finish(.failure(ClientError("未能获取位置，请重试")))
                return
            }
            self.finish(.success(LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(.failure(ClientError("定位失败，请检查定位开关后重试")))
        }
    }
}