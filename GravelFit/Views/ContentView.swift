import SwiftUI
import Charts
import AppKit

enum Destination: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", live = "Live Bike Fit", sessions = "Recorded Sessions", comparison = "Before / After", bikes = "Bike Profiles", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .live: "figure.outdoor.cycle"
        case .sessions: "film.stack"
        case .comparison: "rectangle.split.2x1"
        case .bikes: "bicycle"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @Bindable var model: LiveFitViewModel
    @State private var destination: Destination? = .dashboard
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var onboarding = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "bicycle").font(.largeTitle).foregroundStyle(.teal)
                    VStack(alignment: .leading) { Text("GravelFit").font(.title2.bold()); Text("LOCAL BIOMECHANICS").font(.caption2).tracking(1.5).foregroundStyle(.secondary) }
                }.padding(.horizontal).padding(.top, 24)
                List(Destination.allCases, selection: $destination) { item in Label(item.rawValue, systemImage: item.symbol).tag(item).padding(.vertical, 6) }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Private by design", systemImage: "lock.shield").font(.caption.bold())
                    Text("Camera frames stay on this Mac. Recordings are saved only when you choose Record.").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 280)
        } detail: {
            Group {
                switch destination ?? .dashboard {
                case .dashboard: DashboardView(model: model, navigate: { destination = $0 })
                case .live: LiveFitView(model: model)
                case .sessions: SessionsView(model: model)
                case .comparison: ComparisonView(model: model)
                case .bikes: BikeProfilesView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .navigationTitle((destination ?? .dashboard).rawValue)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 8) {
                        Circle().fill(model.camera.state == .connected ? Color.teal : Color.secondary).frame(width: 7, height: 7)
                        Text(model.camera.state.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem { Button { model.calibration.begin() } label: { Label("Calibrate", systemImage: "viewfinder") }.disabled(model.busy) }
            }
        }
        .tint(.teal)
        .sheet(isPresented: $onboarding) { OnboardingView { hasSeenOnboarding = true; onboarding = false; model.calibration.begin() } }
        .sheet(isPresented: $model.calibration.isPresented, onDismiss: {
            if destination != .live { model.stopLiveCapture() }
        }) { CalibrationView(model: model) }
        .sheet(item: Binding(get: { model.videoTrimRequest }, set: { if $0 == nil { model.cancelVideoTrim() } })) { request in
            VideoTrimView(request: request, cancel: { model.cancelVideoTrim() }, analyze: { model.analyzeTrimmedVideo(request, range: $0) })
        }
        .alert("GravelFit", isPresented: Binding(get: { model.error != nil || model.repository.error != nil }, set: { if !$0 { model.error = nil; model.repository.error = nil } })) {
            Button("OK") { model.error = nil; model.repository.error = nil }
        } message: { Text(model.error ?? model.repository.error ?? "") }
        .onAppear { onboarding = !hasSeenOnboarding }
        .onChange(of: destination) { _, newDestination in
            if newDestination != .live { model.stopLiveCapture() }
        }
        .onChange(of: model.settings) { _, _ in model.updateSettings() }
    }
}

struct DashboardView: View {
    @Bindable var model: LiveFitViewModel
    var navigate: (Destination) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find your balance.").font(.system(size: 36, weight: .semibold))
                    Text("Comfort, control and aerodynamic efficiency for your gravel position.").font(.title3).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    dashboardCard("Saved sessions", value: "\(model.repository.sessions.count)", symbol: "film.stack")
                    dashboardCard("Bike profiles", value: "\(model.repository.bikes.count)", symbol: "bicycle")
                    dashboardCard("Calibration", value: model.settings.calibrated ? "Ready" : "Required", symbol: "viewfinder")
                }
                HStack(alignment: .top, spacing: 24) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 18) {
                            Label("Start a fitting", systemImage: "figure.outdoor.cycle").font(.title2.bold())
                            Text("Set up a side view with your bike on a trainer. Calibrate the camera, then pedal steadily to collect repeated measurements.").foregroundStyle(.secondary)
                            Button("Open Live Bike Fit") { navigate(.live) }.buttonStyle(.borderedProminent)
                            Button("Camera calibration") { model.calibration.begin() }
                            Button("Import a recorded video…") { model.importVideo() }.disabled(model.busy)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("A useful measurement starts with a clear view.").font(.title3.bold())
                            Label("Camera perpendicular to the bicycle", systemImage: "camera")
                            Label("Whole visible-side limb inside frame", systemImage: "figure")
                            Label("Even lighting and steady pedaling", systemImage: "sun.max")
                            Text("2D angles are estimates. Reference ranges are adjustable starting points. Crank positions require manual annotation in a recorded session.").font(.callout).foregroundStyle(.secondary)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let progress = model.importProgress {
                    ProgressView(model.videoProcessingStage, value: progress)
                    Button("Cancel import") { model.cancelImport() }
                }
                Text("Recent sessions").font(.title2.bold())
                if model.repository.sessions.isEmpty {
                    ContentUnavailableView("Your first fit starts here", systemImage: "waveform.path", description: Text("Record a session or save live measurements to build your history."))
                } else {
                    ForEach(model.repository.sessions.prefix(5)) { session in
                        HStack {
                            Image(systemName: session.isBaseline ? "flag.fill" : "film").foregroundStyle(.teal)
                            VStack(alignment: .leading) { Text(session.name).font(.headline); Text(session.created.formatted()).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("\(Int(session.duration)) s · \(session.strokes.count) strokes").foregroundStyle(.secondary)
                            Button("View") { navigate(.sessions) }
                        }.padding().background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.padding(32)
        }
    }
    private func dashboardCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: symbol).foregroundStyle(.secondary); Text(value).font(.system(size: 30, weight: .medium, design: .rounded)) }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct OnboardingView: View {
    var finish: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "bicycle").font(.system(size: 52)).foregroundStyle(.teal)
            Text("Welcome to GravelFit").font(.largeTitle.bold())
            Text("Turn a side-view camera into a local cycling analysis tool.").font(.title3)
            Label("Use an iPhone with Continuity Camera or a standard webcam.", systemImage: "iphone.and.arrow.forward")
            Label("Vision analyzes posture on this Mac. No accounts or uploads.", systemImage: "lock.shield")
            Label("Record sessions, compare adjustments, and annotate crank positions.", systemImage: "chart.xyaxis.line")
            Text("Use a stable trainer, keep the whole cyclist visible, and make small measured adjustments. Side-view analysis cannot measure lateral pelvic rocking or diagnose discomfort.").foregroundStyle(.secondary)
            Button("Set up my camera", action: finish).buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(40).frame(width: 620)
    }
}
