import SwiftUI
import AppKit

struct CalibrationView: View {
    @Bindable var model: LiveFitViewModel
    @Environment(\.dismiss) private var dismiss
    private var manager: CalibrationManager { model.calibration }
    private var canAdvance: Bool {
        switch manager.step {
        case 0: model.camera.state == .connected
        case 3: (model.sample?.confidence ?? 0) >= model.settings.confidenceThreshold
        case 6: manager.reliable && model.engine.cycles.strokes.count >= 3
        default: true
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Camera calibration").font(.title.bold()); Spacer(); Text("\(manager.step + 1) / 8").foregroundStyle(.secondary) }
            ProgressView(value: Double(manager.step), total: 7)
            Text(manager.instructions[manager.step]).font(.title3).fixedSize(horizontal: false, vertical: true)
            if manager.step == 0 { CameraControls(model: model) }
            LiveVideoPanel(model: model).frame(height: 280)
            if manager.step == 4 {
                HStack { Text("Floor slope (°)"); TextField("0", value: $model.settings.floorAngle, format: .number).textFieldStyle(.roundedBorder).frame(width: 100) }
            }
            if manager.step == 5 {
                Picker("Visible side", selection: $model.settings.side) { ForEach(RiderSide.allCases) { Text($0.title).tag($0) } }
                Picker("Hands", selection: $model.settings.handPosition) { ForEach(HandPosition.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            }
            if manager.step == 6 {
                Text("\(manager.goodFrames) / \(manager.totalFrames) reliable frames · \(model.engine.cycles.strokes.count) detected strokes").font(.callout.monospacedDigit())
                ProgressView(value: min(1, manager.elapsed / 10))
                if !manager.reliable { Text("Keep pedaling until at least 80% of frames are reliable over 10 seconds.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Back") { manager.step = max(0, manager.step - 1) }.disabled(manager.step == 0)
                Button(manager.step == 7 ? "Start analysis" : "Confirm & continue") {
                    if manager.step == 7 { model.settings.calibrated = true; model.updateSettings(); dismiss() }
                    else {
                        manager.step += 1
                        if manager.step == 6 { manager.startedAt = nil; manager.goodFrames = 0; manager.totalFrames = 0; model.engine.reset() }
                    }
                }.buttonStyle(.borderedProminent).disabled(!canAdvance)
            }
        }.padding(28).frame(width: 720)
    }
}

struct GuidedFitView: View {
    @Bindable var model: LiveFitViewModel
    @State private var amount = 0.0
    @State private var notes = ""
    @State private var physicalConfirmation = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Step", selection: $model.fitStep) { ForEach(FitStep.allCases) { Text("\($0.rawValue + 1). \($0.title)").tag($0) } }.disabled(model.pendingAdjustmentID != nil)
                Text(model.fitStep.explanation).foregroundStyle(.secondary)
                Text(BikeFitRecommendationEngine.guidance(step: model.fitStep, engine: model.engine, settings: model.settings)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    ForEach([MetricKind.kneeFlexion, .hipAngle, .torsoAngle, .elbowAngle]) { kind in
                        VStack(alignment: .leading) { Text(kind.title).font(.caption).foregroundStyle(.secondary); Text(formatted(model.sample?.values[kind])).font(.title3.monospacedDigit()) }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let progress = model.captureProgress {
                    ProgressView(model.pendingAdjustmentID == nil ? "Capturing 8 seconds of reliable measurements…" : "Capturing fresh measurements after your adjustment…", value: progress)
                    Button("Cancel capture") { model.cancelMeasurement() }
                } else {
                    Button(model.pendingAdjustmentID == nil ? "Capture measurement before adjustment" : "Capture measurement after adjustment") { model.captureMeasurement() }.disabled(model.camera.state != .connected)
                }
                Text("Captures compare eight-second averages across pedal phases. Saddle-height guidance uses repeated maximum-extension values separately.").font(.caption).foregroundStyle(.secondary)
                if !model.lastCapture.isEmpty, model.pendingAdjustmentID == nil {
                    HStack {
                        Text("Measured change")
                        TextField("Amount", value: $amount, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                        Text(model.fitStep.unit).foregroundStyle(.secondary)
                        Text("Positive = increase; negative = decrease").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("What changed and how does it feel?", text: $notes).textFieldStyle(.roundedBorder)
                    Toggle("I made and measured this physical adjustment", isOn: $physicalConfirmation)
                    Button("Confirm adjustment & remeasure") { model.confirmAdjustment(amount: amount, notes: notes); physicalConfirmation = false; notes = ""; amount = 0 }.buttonStyle(.borderedProminent).disabled(!physicalConfirmation || amount == 0 || !amount.isFinite || model.camera.state != .connected)
                }
                if let pending = model.pendingAdjustmentID, model.adjustments.contains(where: { $0.id == pending }) {
                    Text("A fresh capture is required before the next adjustment. Keep pedaling with all joints visible.").font(.caption).foregroundStyle(.orange)
                }
                ForEach(model.adjustments.suffix(5).reversed()) { adjustment in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(adjustment.step.title): \(adjustment.amount, specifier: "%+.1f") \(adjustment.unit)").font(.headline)
                        if let after = adjustment.after {
                            ForEach([MetricKind.kneeFlexion, .hipAngle, .torsoAngle, .elbowAngle]) { kind in
                                if let beforeValue = adjustment.before[kind], let afterValue = after[kind] {
                                    Text("\(kind.title): \(beforeValue, specifier: "%.1f")° → \(afterValue, specifier: "%.1f")° (Δ \(afterValue - beforeValue, specifier: "%+.1f")°)").font(.caption.monospacedDigit())
                                }
                            }
                        } else { Text("Waiting for fresh measurement").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack { Spacer(); Button("Next step") { if let next = FitStep(rawValue: model.fitStep.rawValue + 1) { model.fitStep = next; model.lastCapture = [:] } }.disabled(model.fitStep == .validation || model.pendingAdjustmentID != nil) }
            }.padding(8)
        }
        .onChange(of: model.fitStep) { _, _ in model.lastCapture = [:]; physicalConfirmation = false }
    }
}

struct SettingsView: View {
    @Bindable var model: LiveFitViewModel
    @State private var confirmDelete = false
    var body: some View {
        Form {
            Section("Capture & tracking") {
                Toggle("Mirror video display", isOn: $model.settings.mirror)
                Picker("Video orientation", selection: Binding(get: { model.videoRotation }, set: { model.settings.rotation = $0 })) {
                    if model.isIPhoneCameraSelected {
                        Text("Portrait").tag(90.0)
                        Text("Portrait upside down").tag(270.0)
                    } else {
                        Text("0°").tag(0.0); Text("90°").tag(90.0); Text("180°").tag(180.0); Text("270°").tag(270.0)
                    }
                }.disabled(model.busy)
                    .onChange(of: model.settings.rotation) { _, _ in model.updateSettings(resetAnalysis: true) }
                HStack { Text("Analysis rate"); Slider(value: $model.settings.analysisFPS, in: 5...30, step: 1); Text("\(Int(model.settings.analysisFPS)) FPS").monospacedDigit().frame(width: 65) }
                HStack { Text("Confidence threshold"); Slider(value: $model.settings.confidenceThreshold, in: 0.3...0.95, step: 0.05); Text("\(Int(model.settings.confidenceThreshold * 100))%").monospacedDigit().frame(width: 65) }
                HStack { Text("Smoothing response"); Slider(value: $model.settings.smoothing, in: 0.1...1, step: 0.05); Text(model.settings.smoothing, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 65) }
                Text("Lower smoothing response reduces jitter and increases lag. Analysis adapts to processing time; preview uses the capture frame rate.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Working reference ranges") {
                rangeEditor("Knee at maximum extension", lower: $model.settings.kneeExtensionRange.lower, upper: $model.settings.kneeExtensionRange.upper)
                rangeEditor("Knee at annotated BDC", lower: $model.settings.bottomDeadCenterRange.lower, upper: $model.settings.bottomDeadCenterRange.upper)
                rangeEditor("Torso to horizontal", lower: $model.settings.torsoRange.lower, upper: $model.settings.torsoRange.upper)
                Text("These starting ranges are configurable, not universal prescriptions. Hip and elbow angles have no universal ideal. Side-view vertical hip motion cannot establish lateral pelvic stability.").font(.caption).foregroundStyle(.secondary)
                if model.settings.kneeExtensionRange.lower > model.settings.kneeExtensionRange.upper || model.settings.bottomDeadCenterRange.lower > model.settings.bottomDeadCenterRange.upper || model.settings.torsoRange.lower > model.settings.torsoRange.upper {
                    Label("A lower bound exceeds its upper bound. That reference is unavailable until corrected.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Local storage & privacy") {
                LabeledContent("Storage", value: model.repository.directory.path).font(.caption)
                Button("Show data in Finder") { NSWorkspace.shared.open(model.repository.directory) }
                Text("No accounts, cloud processing, analytics or network requests. Imported videos are copied into local app storage. No microphone audio is captured.").font(.caption).foregroundStyle(.secondary)
                Button("Delete all saved data…", role: .destructive) { confirmDelete = true }.disabled(model.busy)
            }
        }.formStyle(.grouped).disabled(model.busy)
            .onChange(of: model.settings) { _, _ in model.updateSettings() }
            .confirmationDialog("Delete all sessions, videos, bikes and settings? This cannot be undone.", isPresented: $confirmDelete) {
                Button("Delete all saved data", role: .destructive) {
                    do { try model.repository.deleteAll(); UserDefaults.standard.removeObject(forKey: "hasSeenOnboarding"); model.settings = model.repository.settings; model.activeBikeID = nil; model.engine.reset(); model.adjustments = []; model.lastCapture = [:]; model.pendingAdjustmentID = nil; model.observations = ""; model.pose = nil; model.sample = nil; model.trails = [] }
                    catch { model.error = error.localizedDescription }
                }
            }
    }
    private func rangeEditor(_ title: String, lower: Binding<Double>, upper: Binding<Double>) -> some View {
        HStack {
            Text(title); Spacer()
            TextField("Low", value: lower, format: .number).frame(width: 60)
            Text("–")
            TextField("High", value: upper, format: .number).frame(width: 60)
            Text("°")
        }.textFieldStyle(.roundedBorder)
    }
}

struct BikeProfilesView: View {
    @Bindable var model: LiveFitViewModel
    @State private var selected: UUID?
    @State private var drafts: [UUID: BikeProfile] = [:]
    @State private var bikeToDelete: BikeProfile?
    var body: some View {
        HSplitView {
            VStack {
                List(model.repository.bikes, selection: $selected) { bike in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(bike.name).font(.headline)
                            if drafts[bike.id].map({ $0 != bike }) == true {
                                Image(systemName: "pencil").accessibilityLabel("Unsaved changes")
                            }
                        }
                        Text(bike.type).font(.caption).foregroundStyle(.secondary)
                    }.tag(bike.id).padding(.vertical, 6)
                        .contextMenu {
                            Button("Delete bike…", role: .destructive) { bikeToDelete = bike }
                                .disabled(!model.canDeleteBike(bike.id))
                        }
                }
                Button("Add bike", systemImage: "plus") {
                    let bike = BikeProfile(name: "New bike")
                    do { try model.repository.saveBike(bike); selected = bike.id }
                    catch { model.error = error.localizedDescription }
                }.padding().disabled(model.busy)
            }.frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            if let bike = model.repository.bikes.first(where: { $0.id == (selected ?? model.activeBikeID) }) {
                editor(for: bike)
            } else {
                ContentUnavailableView("Bike profiles are optional", systemImage: "bicycle", description: Text("Use Live Bike Fit without a profile, or add a bike to keep its measured setup with your sessions."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selected = model.activeBikeID ?? model.repository.bikes.first?.id }
        .alert("Delete bike profile?", isPresented: Binding(get: { bikeToDelete != nil }, set: { if !$0 { bikeToDelete = nil } }), presenting: bikeToDelete) { bike in
            Button("Cancel", role: .cancel) { bikeToDelete = nil }
            Button("Delete bike", role: .destructive) {
                if model.deleteBike(bike.id) {
                    drafts.removeValue(forKey: bike.id)
                    if selected == bike.id { selected = model.activeBikeID ?? model.repository.bikes.first?.id }
                }
                bikeToDelete = nil
            }.disabled(!model.canDeleteBike(bike.id))
        } message: { bike in
            Text("Delete \"\(bike.name)\"? Saved sessions and their recorded setups will be kept. You can continue fitting without a bike profile.")
        }
    }
    private func editor(for bike: BikeProfile) -> some View {
        let draft = Binding(get: { drafts[bike.id] ?? bike }, set: { drafts[bike.id] = $0 })
        let hasChanges = draft.wrappedValue != bike
        return Form {
            Section("Bike & rider") {
                TextField("Bike name", text: draft.name).textFieldStyle(.roundedBorder)
                Picker("Type", selection: draft.type) { Text("Gravel").tag("Gravel"); Text("Road").tag("Road"); Text("Endurance").tag("Endurance") }
                TextField("Rider notes", text: draft.riderNotes, axis: .vertical).textFieldStyle(.roundedBorder)
            }
            Section("Measured setup") {
                setupField("Crank length", value: draft.crankLength)
                setupField("Saddle height", value: draft.saddleHeight)
                setupField("Saddle setback", value: draft.saddleSetback)
                setupField("Saddle tilt", value: draft.saddleTilt, unit: "°")
                setupField("Handlebar drop", value: draft.handlebarDrop)
                setupField("Effective reach", value: draft.effectiveReach)
                setupField("Stem length", value: draft.stemLength)
                setupField("Handlebar width", value: draft.handlebarWidth)
                TextField("Cleat notes", text: draft.cleatNotes, axis: .vertical).textFieldStyle(.roundedBorder)
            }
            Section {
                HStack {
                    Button("Save changes") {
                        do {
                            try model.repository.saveBike(draft.wrappedValue)
                            drafts.removeValue(forKey: bike.id)
                        } catch { model.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(!hasChanges)
                    Button("Revert changes") { drafts.removeValue(forKey: bike.id) }.disabled(!hasChanges)
                    Spacer()
                    Text(hasChanges ? "Unsaved changes" : "All changes saved").font(.caption).foregroundStyle(.secondary)
                }
                Button(model.activeBikeID == bike.id ? "Active bike for new sessions" : "Use for new fitting sessions") { model.selectBike(bike.id) }
                    .disabled(model.activeBikeID == bike.id || !model.canChangeBike || hasChanges)
                Button("Delete bike…", role: .destructive) { bikeToDelete = bike }
                    .disabled(!model.canDeleteBike(bike.id))
                if bike.id == model.activeBikeID && !model.canDeleteBike(bike.id) && !model.busy {
                    Text("Start a new fit before deleting the bike used by your current measurements and adjustments.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped).disabled(model.busy).id(bike.id)
    }
    private func setupField(_ title: String, value: Binding<Double>, unit: String = "mm") -> some View { HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 100); Text(unit).foregroundStyle(.secondary) } }
}
