import Foundation
import Observation

/// Re-runs `body` whenever any `@Observable` property it reads changes (main actor).
@MainActor
enum ObservationLoop {
    static func observe(_ body: @escaping @MainActor () -> Void) {
        withObservationTracking {
            body()
        } onChange: {
            Task { @MainActor in
                observe(body)
            }
        }
    }
}
