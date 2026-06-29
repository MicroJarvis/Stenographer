import SwiftUI

@main
struct StenographerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("自动整理会议") {
                    NotificationCenter.default.post(name: .summarizeCurrentMeeting, object: nil)
                }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let startNewRecording = Notification.Name("Stenographer.startNewRecording")
    static let summarizeCurrentMeeting = Notification.Name("Stenographer.summarizeCurrentMeeting")
}
