import SwiftUI
import QuickTranscriberLib

// MARK: - Menu Notification Names

extension Notification.Name {
    static let menuCopyAll = Notification.Name("QuickTranscriber.menuCopyAll")
    static let menuExport = Notification.Name("QuickTranscriber.menuExport")
    static let menuClear = Notification.Name("QuickTranscriber.menuClear")
    static let menuIncreaseFontSize = Notification.Name("QuickTranscriber.menuIncreaseFontSize")
    static let menuDecreaseFontSize = Notification.Name("QuickTranscriber.menuDecreaseFontSize")
    static let menuIsRecordingQuery = Notification.Name("QuickTranscriber.menuIsRecordingQuery")
}

@main
struct QuickTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Replace the About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About Quick Transcriber") {
                    appDelegate.showAboutWindow()
                }
            }

            // File menu
            CommandGroup(after: .newItem) {
                Button("Export...") {
                    NotificationCenter.default.post(name: .menuExport, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            // Edit menu
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy All") {
                    NotificationCenter.default.post(name: .menuCopyAll, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Clear Transcription") {
                    NotificationCenter.default.post(name: .menuClear, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }

            // View menu - font size
            CommandGroup(after: .toolbar) {
                Button("Increase Font Size") {
                    NotificationCenter.default.post(name: .menuIncreaseFontSize, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Font Size") {
                    NotificationCenter.default.post(name: .menuDecreaseFontSize, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Check if recording is active via notification
        var isRecording = false
        let semaphore = DispatchSemaphore(value: 0)

        NotificationCenter.default.post(
            name: .menuIsRecordingQuery,
            object: nil,
            userInfo: ["callback": { (recording: Bool) in
                isRecording = recording
                semaphore.signal()
            } as (Bool) -> Void]
        )

        // Give a brief moment for the response
        _ = semaphore.wait(timeout: .now() + 0.1)

        guard isRecording else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Recording in Progress"
        alert.informativeText = "A transcription is currently being recorded. Are you sure you want to quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - About Window

    func showAboutWindow() {
        if let existingWindow = aboutWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Quick Transcriber"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        aboutWindow = window
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Quick Transcriber")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Real-time transcription powered by WhisperKit")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 300, height: 200)
    }
}
