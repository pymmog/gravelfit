import SwiftUI
import Charts
import AppKit

struct LiveFitView: View {
    @Bindable var model: LiveFitViewModel
    @State private var showGuide = true
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CameraControls(model: model)
                    HStack {
                        Picker("Bike", selection: Binding(get: { model.activeBikeID }, set: { model.selectBike($0) })) {
                            Text("No bike profile").tag(nil as UUID?)
                            ForEach(model.repository.bikes) { Text($0.name).tag(Optional($0.id)) }
                        }.frame(maxWidth: 280).disabled(!model.canChangeBike)
                        Picker("Hands", selection: $model.settings.handPosition) { ForEach(HandPosition.allCases) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 180).disabled(model.busy || model.pendingAdjustmentID != nil || model.captureProgress != nil)
                        Spacer()
                    }
                    if model.activeBikeID == nil {
                        Text("Fit from camera measurements. You can record, save metrics and follow the assistant without entering bike dimensions.").font(.caption).foregroundStyle(.secondary)
                    }
                    LiveVideoPanel(model: model).frame(minHeight: 360, idealHeight: 470)
                    HStack {
                        TextField("Session name", text: $model.sessionName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Button(model.isRecording ? "Stop recording" : "Record session", systemImage: model.isRecording ? "stop.fill" : "record.circle") { model.isRecording ? model.stopRecording() : model.startRecording() }
                            .tint(model.isRecording ? .red : .teal).buttonStyle(.borderedProminent).disabled(model.isFinishing || model.importProgress != nil || model.camera.state != .connected)
                        Button("Save metrics", systemImage: "square.and.arrow.down") { model.saveMeasurements() }.disabled(model.sample == nil || model.busy)
                        Spacer()
                        Button { openWindow(id: "analysis") } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Open full-screen video analysis")
                    }
                    if model.isFinishing { ProgressView("Finalizing video and saving session…").controlSize(.small) }
                    DisclosureGroup("Overlay controls") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Toggle("Skeleton", isOn: $model.settings.showSkeleton); Toggle("Joints", isOn: $model.settings.showJoints); Toggle("Angles", isOn: $model.settings.showAngles) }
                            HStack { Toggle("Angle arcs", isOn: $model.settings.showArcs); Toggle("Trails", isOn: $model.settings.showTrails) }
                            HStack {
                                ForEach([MetricKind.kneeFlexion, .hipAngle, .torsoAngle, .elbowAngle]) { kind in
                                    Toggle(kind.title, isOn: Binding(get: { model.settings.overlayMetrics.contains(kind) }, set: { enabled in if enabled { model.settings.overlayMetrics.insert(kind) } else { model.settings.overlayMetrics.remove(kind) } })).font(.caption)
                                }
                            }
                        }.padding(.top, 8)
                    }
                    HStack { Text("Guided gravel fit").font(.title2.bold()); Spacer(); Button("New fit") { model.beginNewFit() }.disabled(model.busy || model.pendingAdjustmentID != nil); Toggle("Show assistant", isOn: $showGuide).toggleStyle(.switch) }
                    if showGuide { GuidedFitView(model: model) }
                    TextField("Comfort, hand pressure, stability and other observations", text: $model.observations, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...6)
                }.padding(20)
            }.frame(minWidth: 550)
            ScrollView {
                MeasurementPanel(model: model).padding(18)
            }.frame(minWidth: 300, idealWidth: 350, maxWidth: 500)
        }
    }
}

struct CameraControls: View {
    @Bindable var model: LiveFitViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Camera", selection: $model.camera.selectedID) {
                    if model.camera.devices.isEmpty { Text("No cameras available").tag("") }
                    ForEach(model.camera.devices) { device in Text(device.name + (device.continuity ? " · iPhone" : "")).tag(device.id) }
                }.frame(maxWidth: 320).disabled(model.busy)
                Button("Refresh", systemImage: "arrow.clockwise") { model.camera.refresh() }.labelStyle(.iconOnly).disabled(model.busy)
                Button(model.camera.state == .connected ? "Disconnect" : "Connect") {
                    if model.camera.state == .connected { model.camera.stop() } else { Task { await model.connectCamera() } }
                }.disabled(model.busy || model.camera.state == .connecting || model.camera.state == .requestingPermission)
                Spacer()
                Picker("Side", selection: $model.settings.side) { ForEach(RiderSide.allCases) { Text($0.title).tag($0) } }.frame(width: 130).disabled(model.busy)
                    .onChange(of: model.settings.side) { _, _ in model.updateSettings(resetAnalysis: true) }
            }
            if model.isIPhoneCameraSelected {
                Label("iPhone records in portrait. Mount it vertically with the whole cyclist in frame.", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.camera.selectedID) { _, _ in
            model.updateSettings(resetAnalysis: true)
            if model.camera.state == .connected { Task { await model.connectCamera() } }
        }
    }
}

struct LiveVideoPanel: View {
    @Bindable var model: LiveFitViewModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            CameraPreview(pipeline: model.camera.pipeline, mirror: model.settings.mirror, rotation: model.videoRotation)
            if let pose = model.pose { SkeletonOverlay(pose: pose, values: model.sample?.values ?? [:], settings: model.settings, trails: model.trails) }
            if model.camera.state != .connected {
                VStack(spacing: 16) {
                    Image(systemName: model.camera.state == .denied ? "camera.badge.ellipsis" : "video.slash").font(.system(size: 48))
                    Text(model.camera.state.title).font(.headline)
                    Text("Use a side view with the entire cyclist in frame.").foregroundStyle(.gray)
                    if model.camera.state == .denied { Button("Open Camera Privacy Settings") { model.camera.openPrivacySettings() } }
                    else { Button("Connect Camera") { Task { await model.connectCamera() } }.disabled(model.camera.state == .connecting) }
                }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(model.trackingMessage, systemImage: (model.sample?.confidence ?? 0) >= model.settings.confidenceThreshold ? "checkmark.circle.fill" : "viewfinder")
                    .font(.caption).padding(8).background(.black.opacity(0.6), in: Capsule())
                if model.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Label("REC  \(Int(model.recordingStarted.map { Date().timeIntervalSince($0) } ?? 0)) s", systemImage: "record.circle.fill").font(.caption.monospacedDigit().bold()).foregroundStyle(.red).padding(8).background(.black.opacity(0.6), in: Capsule())
                    }
                }
            }.foregroundStyle(.white).padding(14)
        }.clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("Live cyclist video with pose overlay")
    }
}

struct FullScreenAnalysisView: View {
    @Bindable var model: LiveFitViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("Live video analysis").font(.headline); Spacer(); Button("Full screen") { NSApp.keyWindow?.toggleFullScreen(nil) }; Button("Done") { dismissWindow(id: "analysis") }.keyboardShortcut(.escape, modifiers: []) }.padding()
            LiveVideoPanel(model: model)
            HStack { ForEach([MetricKind.kneeFlexion, .hipAngle, .torsoAngle, .elbowAngle]) { kind in VStack { Text(kind.title).font(.caption); Text(formatted(model.sample?.values[kind], unit: "°")).font(.title2.monospacedDigit()) }.frame(maxWidth: .infinity) } }.padding()
        }.padding(12).frame(minWidth: 1000, minHeight: 700)
    }
}

func formatted(_ value: Double?, unit: String = "°") -> String {
    value.map { String(format: "%.0f", $0) + unit } ?? "—"
}

struct MetricCard: View {
    let kind: MetricKind
    let statistics: MetricStatistics
    var reference: ReferenceRange?
    var confidence: Double
    var color: Color {
        guard statistics.current != nil else { return .secondary }
        if kind == .confidence { return (statistics.current ?? 0) < 60 ? .orange : .teal }
        if let reference {
            switch reference.evaluate(statistics.current, confidence: confidence) { case .above, .below: return .orange; case .unavailable: return .secondary; case .within: return .teal }
        }
        if kind == .elbowAngle, (statistics.current ?? 0) > 165 { return .orange }
        if kind == .pelvicMovement, (statistics.current ?? 0) > 5 { return .orange }
        return .primary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(kind.title).font(.headline); Spacer(); Image(systemName: "info.circle").foregroundStyle(.secondary).help(kind.note) }
            Text(formatted(statistics.current, unit: kind.unit)).font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
            HStack(spacing: 20) {
                statistic("MIN", statistics.minimum); statistic("MAX", statistics.maximum); statistic("30 S AVG", statistics.average)
            }
            if let reference { Text("Working range \(Int(reference.lower))–\(Int(reference.upper))°").font(.caption).foregroundStyle(.secondary) }
            if statistics.current == nil { Text("Unavailable · reliable joints required").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    private func statistic(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary); Text(formatted(value, unit: kind.unit)).font(.caption.monospacedDigit()) }
    }
}

struct MeasurementPanel: View {
    @Bindable var model: LiveFitViewModel
    @State private var chartMetric: MetricKind = .kneeFlexion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Live measurements").font(.title3.bold()); Spacer(); Text("2D").font(.caption.bold()).foregroundStyle(.secondary) }
            ForEach(MetricKind.allCases) { kind in
                MetricCard(kind: kind, statistics: model.currentStatistics[kind] ?? MetricStatistics(), reference: kind == .torsoAngle ? model.settings.torsoRange : nil, confidence: model.sample?.confidence ?? 0)
            }
            GroupBox("Pedal strokes") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.engine.cycles.strokes.count) detected strokes").font(.headline)
                    Text("Maximum extension: \(formatted(model.engine.cycles.maximumExtension))")
                    Text("Between-stroke SD: \(formatted(model.engine.cycles.extensionVariation))")
                    Text("Extension reference: \(Int(model.settings.kneeExtensionRange.lower))–\(Int(model.settings.kneeExtensionRange.upper))°").font(.caption).foregroundStyle(.secondary)
                    Text("BDC / TDC: unavailable live. Annotate recorded frames to measure crank positions.").font(.caption).foregroundStyle(.secondary)
                    Text("Hip motion >5% flags an observation to repeat; it is not a validated saddle-instability threshold.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Picker("Chart", selection: $chartMetric) { ForEach(MetricKind.allCases) { Text($0.title).tag($0) } }
            MeasurementChart(samples: model.engine.history, metric: chartMetric).frame(height: 180)
            Text("Angles depend on camera geometry and tracking. Confidence describes detection, not angular accuracy. Live statistics use a rolling 30-second window.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MeasurementChart: View {
    let samples: [MetricSample]
    let metric: MetricKind
    var body: some View {
        let origin = samples.first?.time ?? 0
        Chart(chartData(samples, metric: metric)) { point in
            LineMark(x: .value("Time (s)", point.time - origin), y: .value(metric.title, point.value), series: .value("Tracking segment", point.segment)).foregroundStyle(.teal)
        }.chartYAxisLabel(metric.unit).chartXAxisLabel("Seconds").accessibilityLabel("\(metric.title) over time")
    }
}

struct SkeletonOverlay: View {
    let pose: PoseFrame
    let values: [MetricKind: Double]
    let settings: FitSettings
    var trails: [PoseFrame] = []
    var body: some View {
        Canvas { context, size in
            func mapped(_ point: Point2D) -> CGPoint {
                let p = VideoOverlayRenderer.map(point, imageWidth: pose.width, imageHeight: pose.height, viewWidth: size.width, viewHeight: size.height, mirrored: settings.mirror)
                return CGPoint(x: p.x, y: p.y)
            }
            if settings.showTrails {
                let names = JointName.limb(settings.side)
                for name in [names.hip, names.knee, names.ankle] {
                    var path = Path()
                    for frame in trails {
                        guard let joint = frame.joints[name], !joint.isPredicted else { continue }
                        let p = mapped(joint.point)
                        if path.isEmpty { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    context.stroke(path, with: .color(.yellow.opacity(0.45)), lineWidth: 2)
                }
            }
            if settings.showSkeleton {
                for (a, b) in JointName.bones {
                    guard let ja = pose.joints[a], let jb = pose.joints[b] else { continue }
                    var path = Path(); path.move(to: mapped(ja.point)); path.addLine(to: mapped(jb.point))
                    let reliable = !ja.isPredicted && !jb.isPredicted
                    context.stroke(path, with: .color(reliable ? .mint : .orange.opacity(0.4)), style: StrokeStyle(lineWidth: 3, dash: reliable ? [] : [4, 4]))
                }
            }
            if settings.showJoints {
                for joint in pose.joints.values {
                    let point = mapped(joint.point)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(joint.isPredicted ? .orange.opacity(0.4) : .white.opacity(joint.confidence)))
                }
            }
            let names = JointName.limb(settings.side)
            let anchors: [(MetricKind, JointName, JointName, JointName)] = [(.kneeFlexion, names.knee, names.hip, names.ankle), (.hipAngle, names.hip, names.shoulder, names.knee), (.elbowAngle, names.elbow, names.shoulder, names.wrist), (.torsoAngle, names.shoulder, names.hip, names.shoulder)]
            for (kind, vertex, a, b) in anchors where settings.overlayMetrics.contains(kind) {
                guard let value = values[kind], let joint = pose.joints[vertex], !joint.isPredicted else { continue }
                let point = mapped(joint.point)
                if settings.showAngles {
                    let text = Text("\(kind == .hipAngle ? "Hip 2D" : kind == .torsoAngle ? "Torso" : kind == .kneeFlexion ? "Knee" : "Elbow") \(Int(value.rounded()))°").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    let labelPoint = CGPoint(x: min(size.width - 70, max(70, point.x + 64)), y: max(16, point.y - 18))
                    context.fill(Path(roundedRect: CGRect(x: labelPoint.x - 62, y: labelPoint.y - 13, width: 124, height: 26), cornerRadius: 5), with: .color(.black.opacity(0.65)))
                    context.draw(text, at: labelPoint)
                }
                if settings.showArcs, kind != .torsoAngle, let ja = pose.joints[a], let jb = pose.joints[b] {
                    let pa = mapped(ja.point), pb = mapped(jb.point)
                    let start = atan2(pa.y - point.y, pa.x - point.x)
                    var difference = atan2(pb.y - point.y, pb.x - point.x) - start
                    while difference > .pi { difference -= 2 * .pi }
                    while difference < -.pi { difference += 2 * .pi }
                    var arc = Path(); arc.addArc(center: point, radius: 22, startAngle: .radians(start), endAngle: .radians(start + difference), clockwise: difference < 0)
                    context.stroke(arc, with: .color(.yellow), lineWidth: 2)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
