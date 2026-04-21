import SwiftUI
import QuickTranscriberLib

// MARK: - Menu Notification Names

extension Notification.Name {
    static let menuCopyAll = Notification.Name("QuickTranscriber.menuCopyAll")
    static let menuExport = Notification.Name("QuickTranscriber.menuExport")
    static let menuClear = Notification.Name("QuickTranscriber.menuClear")
    static let menuIncreaseFontSize = Notification.Name("QuickTranscriber.menuIncreaseFontSize")
    static let menuDecreaseFontSize = Notification.Name("QuickTranscriber.menuDecreaseFontSize")
    static let menuResetFontSize = Notification.Name("QuickTranscriber.menuResetFontSize")
    static let menuToggleRecording = Notification.Name("QuickTranscriber.menuToggleRecording")
    static let menuIsRecordingQuery = Notification.Name("QuickTranscriber.menuIsRecordingQuery")
}

@main
struct QuickTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = TranscriptionViewModel()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("lastUpdateCheck") private var lastUpdateCheck: Double = 0

    @State private var showUpdateAvailableAlert = false
    @State private var showNoUpdateAlert = false
    @State private var showUpdateErrorAlert = false
    @State private var isManualCheck = false

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    checkForUpdatesOnLaunch()
                }
                .alert("Update Available", isPresented: $showUpdateAvailableAlert) {
                    Button("Download and Install") {
                        Task { await updateChecker.downloadAndInstall() }
                    }
                    Button("View Release Page") {
                        updateChecker.openReleasePage()
                    }
                    Button("Later", role: .cancel) {}
                } message: {
                    if let release = updateChecker.latestRelease {
                        Text("A new version (\(release.tagName)) is available. Current version: \(Constants.Version.versionString)")
                    }
                }
                .alert("No Updates Available", isPresented: $showNoUpdateAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("You are running the latest version (\(Constants.Version.versionString)).")
                }
                .alert("Update Check Failed", isPresented: $showUpdateErrorAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(updateChecker.errorMessage ?? "An unknown error occurred.")
                }
        }
        .commands {
            // Replace the About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About Quick Transcriber") {
                    appDelegate.showAboutWindow()
                }

                Button("Check for Updates...") {
                    isManualCheck = true
                    Task { await performUpdateCheck() }
                }
                .disabled(updateChecker.isChecking)
            }

            // File menu
            CommandGroup(after: .newItem) {
                Button(viewModel.isRecording ? "Stop" : "Record") {
                    NotificationCenter.default.post(name: .menuToggleRecording, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

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

                Button("Reset Font Size") {
                    NotificationCenter.default.post(name: .menuResetFontSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }

    private func checkForUpdatesOnLaunch() {
        let now = Date().timeIntervalSince1970
        let oneDayInSeconds: Double = 24 * 60 * 60
        guard now - lastUpdateCheck >= oneDayInSeconds else { return }

        isManualCheck = false
        Task { await performUpdateCheck() }
    }

    private func performUpdateCheck() async {
        await updateChecker.checkForUpdates()
        lastUpdateCheck = Date().timeIntervalSince1970

        if updateChecker.updateAvailable {
            showUpdateAvailableAlert = true
        } else if updateChecker.errorMessage != nil {
            if isManualCheck {
                showUpdateErrorAlert = true
            }
        } else if isManualCheck {
            showNoUpdateAlert = true
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Intercept space key when no editable text view has focus
        // (SwiftUI's .onKeyPress requires focus, which is absent on launch)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, // space
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }
            // Let editable text views (e.g., Settings TextFields) handle space normally
            if let responder = event.window?.firstResponder as? NSTextView,
               responder.isEditable {
                return event
            }
            NotificationCenter.default.post(name: .menuToggleRecording, object: nil)
            return nil
        }
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
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Quick Transcriber")
                .font(.title)
                .fontWeight(.bold)

            Text(Constants.Version.versionString)
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
