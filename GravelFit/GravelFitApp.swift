import SwiftUI

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: LiveFitViewModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.busy else { model.camera.stop(); return .terminateNow }
        model.prepareToTerminate { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main struct GravelFitApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @State private var model = LiveFitViewModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1120, minHeight: 720)
                .onAppear { appDelegate.model = model }
                .onDisappear { model.stopLiveCapture() }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Video…") { model.importVideo() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(model.busy)
                Button(model.isRecording ? "Stop Recording" : "Record Session") { model.isRecording ? model.stopRecording() : model.startRecording() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.isFinishing || model.importProgress != nil)
                Button("Save Measurements") { model.saveMeasurements() }.keyboardShortcut("s").disabled(model.busy)
            }
        }
        Settings { SettingsView(model: model).frame(width: 640, height: 620).onAppear { model.stopLiveCapture() } }
        Window("GravelFit — Video Analysis", id: "analysis") {
            FullScreenAnalysisView(model: model)
        }.defaultSize(width: 1280, height: 820)
    }
}
