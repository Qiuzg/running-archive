import SwiftUI
import SwiftData

@main
struct RunningArchiveSyncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [CachedHealthWorkout.self, CachedHealthRoute.self])
    }
}
