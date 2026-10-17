import SwiftUI
import SwiftData

@main
struct RunningArchiveSyncApp: App {
    @UIApplicationDelegateAdaptor(RunningArchiveAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [CachedHealthWorkout.self, CachedHealthRoute.self, CachedArchiveState.self])
    }
}
