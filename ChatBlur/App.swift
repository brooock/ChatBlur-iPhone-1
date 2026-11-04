import SwiftUI

@main
struct ChatBlurApp: App {
    init() {
        // Remove imported copies and exports left over from an earlier session.
        VideoProcessor.cleanupTemporaryFiles()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
