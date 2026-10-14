import SwiftUI
import AVKit
import Charts

@MainActor @Observable final class VideoInspector {
    var player: AVPlayer?
    var image: CGImage?
    var pose: PoseFrame?
    var values: [MetricKind: Double] = [:]
    var time = 0.0
    var duration = 0.0
    var fps = 30.0
    var loading = false
    var analyzing = false
    var isPlaying = false
    var inspectedTime: Double?
    var error: String?
    private var generation = 0
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    private var url: URL?
    private var settings = FitSettings()
    @ObservationIgnored private let decode: @Sendable (URL, Double) async throws -> DecodedVideoFrame
    @ObservationIgnored private let analyze: @Sendable (DecodedVideoFrame) async throws -> PoseFrame
    @ObservationIgnored private let timeout: Duration
    init(decode: (@Sendable (URL, Double) async throws -> DecodedVideoFrame)? = nil,
         analyze: (@Sendable (DecodedVideoFrame) async throws -> PoseFrame)? = nil,
         timeout: Duration = .seconds(10)) {
        let decoder = OfflineAnalyzer()
        let detector = FramePoseAnalyzer()
        self.decode = decode ?? { try await decoder.decodeFrame(url: $0, time: $1) }
        self.analyze = analyze ?? { try await detector.analyze($0) }
        self.timeout = timeout
    }
    func cancelInspection() {
        task?.cancel(); task = nil; timeoutTask?.cancel(); timeoutTask = nil; generation += 1
        loading = false; analyzing = false
    }
    func close() {
        metadataTask?.cancel(); metadataTask = nil
        cancelInspection()
        if let observer { player?.removeTimeObserver(observer); self.observer = nil }
        player?.pause(); player = nil; image = nil; pose = nil; values = [:]; url = nil; inspectedTime = nil; error = nil; isPlaying = false
    }
    func open(url: URL, settings: FitSettings, duration: Double) {
        close(); self.url = url; self.settings = settings; self.duration = duration; time = 0; fps = 30
        player = AVPlayer(url: url)
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in guard let self, self.player?.rate != 0 else { return }; self.time = max(0, time.seconds) }
        }
        metadataTask = Task {
            if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
               let rate = try? await track.load(.nominalFrameRate), rate > 0,
               !Task.isCancelled, self.url == url { fps = Double(rate) }
        }
    }
    func inspect(at desired: Double) {
        guard let url, desired.isFinite else { return }
        player?.pause(); isPlaying = false; cancelInspection()
        let ticket = generation
        loading = true; image = nil; pose = nil; values = [:]; inspectedTime = nil; error = nil
        let bounded = max(0, min(max(0, duration - 1 / fps), desired))
        time = bounded
        let settings = settings
        task = Task {
            defer {
                if generation == ticket { loading = false; analyzing = false; timeoutTask?.cancel(); timeoutTask = nil }
            }
            do {
                let decoded = try await decode(url, bounded)
                guard !Task.isCancelled, generation == ticket else { return }
                image = decoded.image; inspectedTime = decoded.time; time = decoded.time; loading = false; analyzing = true
                player?.seek(to: CMTime(seconds: decoded.time, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
                let raw = try await analyze(decoded)
                guard !Task.isCancelled, generation == ticket else { return }
                pose = raw; values = BiomechanicsEngine.measure(raw, settings: settings)
            } catch {
                if generation == ticket && !Task.isCancelled {
                    self.error = image == nil ? "Cannot inspect frame: \(error.localizedDescription)" : "Pose analysis unavailable. You can still mark the crank position; joint angles will be unavailable. \(error.localizedDescription)"
                }
            }
        }
        timeoutTask = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard generation == ticket else { return }
            task?.cancel(); loading = false; analyzing = false
            error = image == nil ? "Frame decoding timed out. Try a nearby frame or retry inspection." : "Pose analysis timed out. You can still mark the crank position; joint angles are unavailable."
        }
    }
    func beginScrubbing() {
        player?.pause(); isPlaying = false; cancelInspection()
        image = nil; pose = nil; values = [:]; inspectedTime = nil
    }
    func annotation(_ position: CrankPosition) -> FrameAnnotation? {
        guard image != nil, let inspectedTime, !loading, !isPlaying else { return nil }
        let names = JointName.limb(settings.side)
        let confidence = [names.shoulder, names.hip, names.knee, names.ankle].map { pose?.joints[$0]?.confidence ?? 0 }.min() ?? 0
        return FrameAnnotation(time: inspectedTime, position: position, kneeFlexion: values[.kneeFlexion], hipAngle: values[.hipAngle], confidence: confidence)
    }
    func step(_ count: Int) { inspect(at: time + Double(count) / fps) }
    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 { beginScrubbing(); isPlaying = true; player.play() }
        else { player.pause(); inspect(at: player.currentTime().seconds) }
    }
}

struct SessionsView: View {
    @Bindable var model: LiveFitViewModel
    @State private var selected: UUID?
    @State private var confirmDelete = false
    @State private var inspector = VideoInspector()
    private var session: FitSession? { model.repository.sessions.first { $0.id == selected } }
    var body: some View {
        HSplitView {
            VStack {
                List(model.repository.sessions, selection: $selected) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { if session.isBaseline { Image(systemName: "flag.fill").foregroundStyle(.teal) }; Text(session.name).font(.headline) }
                        Text(session.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(session.duration)) s · \(session.samples.count) samples").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).tag(session.id)
                }
                Button("Import video…", systemImage: "square.and.arrow.down") { model.importVideo() }.disabled(model.busy).padding()
                if let progress = model.importProgress { ProgressView(model.videoProcessingStage, value: progress).padding(.horizontal); Button("Cancel") { model.cancelImport() }.padding(.bottom) }
            }.frame(minWidth: 200, idealWidth: 245, maxWidth: 340)
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading) { Text(session.name).font(.title.bold()); Text(session.created.formatted()).foregroundStyle(.secondary) }
                            Spacer()
                            Menu("Export") { Button("Measurements CSV…") { model.export(session, format: "csv") }; Button("Full session JSON…") { model.export(session, format: "json") }; Button("Local summary…") { model.export(session, format: "txt") } }
                            Button(session.isBaseline ? "Baseline" : "Set baseline", systemImage: "flag") { do { try model.repository.setBaseline(session.id) } catch { model.error = error.localizedDescription } }
                            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(model.busy)
                        }
                        if let url = model.repository.videoURL(session), FileManager.default.fileExists(atPath: url.path) {
                            Button("Trim & analyze video…", systemImage: "scissors") { model.prepareVideoTrim(session) }.disabled(model.busy)
                            SessionVideoView(inspector: inspector, session: session, annotate: { position in annotate(position, session: session) })
                        } else {
                            ContentUnavailableView("Measurements-only session", systemImage: "waveform.path", description: Text("Video is recorded only after an explicit Record action. Crank annotations require a saved video."))
                        }
                        SessionMetricSummary(session: session)
                        MeasurementChart(samples: session.samples, metric: .kneeFlexion).frame(height: 230)
                        Text("Manual crank annotations").font(.title3.bold())
                        if session.annotations.isEmpty { Text("Pause a recorded frame and inspect the crank, then mark TDC or BDC. Maximum leg extension alone does not identify crank position.").foregroundStyle(.secondary) }
                        ForEach(session.annotations.sorted(by: { $0.time < $1.time })) { annotation in
                            HStack {
                                Text(annotation.position == .bottomDeadCenter ? "Bottom dead center" : "Top dead center")
                                Text("\(annotation.time, specifier: "%.3f") s").monospacedDigit()
                                Spacer()
                                Text("Knee \(formatted(annotation.kneeFlexion)) · Hip 2D \(formatted(annotation.hipAngle))")
                                Button { inspector.inspect(at: annotation.time) } label: { Image(systemName: "play.rectangle") }
                                Button(role: .destructive) { var edited = session; edited.annotations.removeAll { $0.id == annotation.id }; save(edited) } label: { Image(systemName: "trash") }
                            }.font(.callout)
                        }
                        Text("Confirmed adjustments").font(.title3.bold())
                        if session.adjustments.isEmpty { Text("No physical adjustments were logged.").foregroundStyle(.secondary) }
                        ForEach(session.adjustments) { adjustment in
                            VStack(alignment: .leading) {
                                Text("\(adjustment.step.title): \(adjustment.amount, specifier: "%+.1f") \(adjustment.unit)").font(.headline)
                                Text(adjustment.notes).foregroundStyle(.secondary)
                                ForEach([MetricKind.kneeFlexion, .hipAngle, .torsoAngle, .elbowAngle]) { kind in
                                    if let before = adjustment.before[kind], let after = adjustment.after?[kind] {
                                        Text("\(kind.title): \(before, specifier: "%.1f")° → \(after, specifier: "%.1f")° (Δ \(after - before, specifier: "%+.1f")°)").font(.caption)
                                    }
                                }
                            }
                        }
                        Text("Observations").font(.title3.bold())
                        TextField("Session observations", text: Binding(get: { session.observations }, set: { value in var edited = session; edited.observations = value; save(edited) }), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...8)
                        Text("2D estimates depend on perspective, framing and occlusion. Tracking confidence is not angular accuracy. Hip angle is shoulder–hip–knee, not anatomical flexion. Lateral pelvic rocking requires a rear view.").font(.caption).foregroundStyle(.secondary)
                    }.padding(24)
                }.frame(minWidth: 650)
            } else { ContentUnavailableView("Select a session", systemImage: "film.stack", description: Text("Review recordings, inspect individual frames and export local measurements.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onAppear { if selected == nil { selected = model.repository.sessions.first?.id }; openSelected() }
        .onChange(of: selected) { _, _ in openSelected() }
        .onDisappear { inspector.close() }
        .confirmationDialog("Delete this session and its video?", isPresented: $confirmDelete) {
            Button("Delete session", role: .destructive) { if let session { do { inspector.close(); try model.repository.delete(session); selected = model.repository.sessions.first?.id } catch { model.error = error.localizedDescription } } }
        }
    }
    private func openSelected() { inspector.close(); if let session, let url = model.repository.videoURL(session) { inspector.open(url: url, settings: session.settings, duration: session.duration) } }
    private func save(_ session: FitSession) { do { try model.repository.save(session) } catch { model.error = error.localizedDescription } }
    private func annotate(_ position: CrankPosition, session: FitSession) {
        guard let annotation = inspector.annotation(position) else { return }
        var edited = session
        edited.annotations.append(annotation)
        save(edited)
    }
}

struct SessionVideoView: View {
    @Bindable var inspector: VideoInspector
    let session: FitSession
    var annotate: (CrankPosition) -> Void
    @State private var confirmedCrank = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color.black
                if let image = inspector.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().scaleEffect(x: session.settings.mirror ? -1 : 1, y: 1)
                    if let pose = inspector.pose { SkeletonOverlay(pose: pose, values: inspector.values, settings: session.settings) }
                } else if let player = inspector.player { VideoPlayer(player: player) }
                if inspector.loading { ProgressView("Inspecting frame…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                else if inspector.analyzing { ProgressView("Analyzing pose…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            }.frame(height: 380).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Button { inspector.step(-1) } label: { Image(systemName: "backward.end") }.help("Previous frame")
                Button { inspector.togglePlayback() } label: { Image(systemName: inspector.isPlaying ? "pause.fill" : "play.fill") }
                Button { inspector.step(1) } label: { Image(systemName: "forward.end") }.help("Next frame")
                Slider(value: $inspector.time, in: 0...max(0.001, inspector.duration), onEditingChanged: { editing in if !editing { inspector.inspect(at: inspector.time) } else { inspector.beginScrubbing() } })
                Text("\(inspector.time, specifier: "%.3f") / \(inspector.duration, specifier: "%.1f") s").font(.caption.monospacedDigit()).frame(width: 165)
            }
            HStack {
                Button("Inspect paused frame") { inspector.inspect(at: inspector.time) }
                if inspector.loading || inspector.analyzing { Button("Cancel inspection") { inspector.cancelInspection() } }
            }
            if let error = inspector.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Toggle("I can clearly identify the crank's top or bottom position in this frame", isOn: $confirmedCrank).font(.callout)
            HStack {
                Button("Mark bottom dead center") { annotate(.bottomDeadCenter); confirmedCrank = false }
                Button("Mark top dead center") { annotate(.topDeadCenter); confirmedCrank = false }
                Spacer()
                Text("Knee \(formatted(inspector.values[.kneeFlexion])) · Hip 2D \(formatted(inspector.values[.hipAngle]))").font(.callout.monospacedDigit())
            }.disabled(!confirmedCrank || inspector.loading || inspector.inspectedTime == nil || inspector.isPlaying)
            Text("Inspect a paused frame, confirm the crank position, then mark TDC or BDC. You can mark a position even when pose analysis is unavailable; joint angles remain unavailable. Frame stepping uses nominal frame rate and labels use the actual decoded timestamp.").font(.caption).foregroundStyle(.secondary)
        }.onChange(of: inspector.time) { _, _ in confirmedCrank = false }
            .onChange(of: inspector.inspectedTime) { _, _ in confirmedCrank = false }
            .onChange(of: session.id) { _, _ in confirmedCrank = false }
    }
}

struct VideoTrimView: View {
    let request: VideoTrimRequest
    var cancel: () -> Void
    var analyze: (VideoTimeRange) -> Void
    @State private var player: AVPlayer
    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var loading = true
    @State private var error: String?
    init(request: VideoTrimRequest, cancel: @escaping () -> Void, analyze: @escaping (VideoTimeRange) -> Void) {
        self.request = request; self.cancel = cancel; self.analyze = analyze
        _player = State(initialValue: AVPlayer(url: request.source))
    }
    private var range: VideoTimeRange { VideoTimeRange(start: start, end: end) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trim before analysis").font(.title.bold())
            Text("Preview the video and select the part you want to analyze. A new trimmed session will be saved; the original stays intact.").foregroundStyle(.secondary)
            VideoPlayer(player: player).frame(height: 340).clipShape(RoundedRectangle(cornerRadius: 10))
            if loading { ProgressView("Loading video…") }
            GroupBox("Selected range") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Start (s)").frame(width: 65, alignment: .leading)
                        TextField("Start seconds", value: $start, format: .number.precision(.fractionLength(3))).labelsHidden().frame(width: 100)
                        Slider(value: $start, in: 0...max(0.001, duration))
                        Button("Set from playhead") { let value = player.currentTime().seconds; if value.isFinite { start = max(0, min(duration, value)) } }
                    }
                    HStack {
                        Text("End (s)").frame(width: 65, alignment: .leading)
                        TextField("End seconds", value: $end, format: .number.precision(.fractionLength(3))).labelsHidden().frame(width: 100).onSubmit { seekToEnd() }
                        Slider(value: $end, in: 0...max(0.001, duration), onEditingChanged: { if !$0 { seekToEnd() } })
                        Button("Set from playhead") { let value = player.currentTime().seconds; if value.isFinite { end = max(0, min(duration, value)) } }
                    }
                    HStack {
                        Text("Selected: \(max(0, range.duration), specifier: "%.2f") s of \(duration, specifier: "%.2f") s").monospacedDigit()
                        Spacer()
                        Button("Use full video") { start = 0; end = duration }
                    }.font(.caption)
                }.padding(8).textFieldStyle(.roundedBorder)
            }.disabled(loading || error != nil)
            if let error { Text(error).foregroundStyle(.orange) }
            else if !loading && !range.isValid(for: duration) { Text("Choose an end after the start, within the video duration.").foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { player.pause(); cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Trim & analyze") { player.pause(); analyze(range) }.buttonStyle(.borderedProminent).disabled(loading || error != nil || !range.isValid(for: duration))
            }
        }.padding(24).frame(width: 850)
        .task {
            do {
                let asset = AVURLAsset(url: request.source)
                let seconds = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard seconds.isFinite, seconds > 0, !tracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                duration = seconds; end = seconds; loading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }
        .onChange(of: start) { _, value in if value.isFinite && value >= 0 && value <= duration { player.pause(); player.seek(to: CMTime(seconds: value, preferredTimescale: 60000)) } }
        .onDisappear { player.pause() }
    }
    private func seekToEnd() {
        if end.isFinite && end > 0 && end <= duration { player.pause(); player.seek(to: CMTime(seconds: max(0, end - 1 / 30), preferredTimescale: 60000)) }
    }
}

struct SessionMetricSummary: View {
    let session: FitSession
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            GridRow { Text("Metric"); Text("Minimum"); Text("Maximum"); Text("Average") }.font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(MetricKind.allCases) { kind in
                let stats = session.statistics[kind] ?? MetricStatistics()
                GridRow { Text(kind.title); Text(formatted(stats.minimum, unit: kind.unit)); Text(formatted(stats.maximum, unit: kind.unit)); Text(formatted(stats.average, unit: kind.unit)) }
            }
            GridRow { Text("Annotated knee at BDC"); Text(annotationAverage(.bottomDeadCenter, knee: true)); Text("Reference"); Text("\(Int(session.settings.bottomDeadCenterRange.lower))–\(Int(session.settings.bottomDeadCenterRange.upper))°") }
            GridRow { Text("Annotated hip near TDC"); Text(annotationAverage(.topDeadCenter, knee: false)); Text("No universal target").gridCellColumns(2) }
        }.monospacedDigit().padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    private func annotationAverage(_ position: CrankPosition, knee: Bool) -> String {
        let values = session.annotations.filter { $0.position == position && $0.confidence >= session.settings.confidenceThreshold }.compactMap { knee ? $0.kneeFlexion : $0.hipAngle }
        return formatted(values.isEmpty ? nil : values.reduce(0,+) / Double(values.count))
    }
}

@MainActor @Observable final class ComparisonPlayback {
    var left: AVPlayer?
    var right: AVPlayer?
    var playing = false
    var time = 0.0
    var duration = 0.0
    var offset = 0.0
    var leftDuration = 0.0
    var rightDuration = 0.0
    var availableStart: Double { max(0, -offset) }
    var availableEnd: Double { max(availableStart, min(leftDuration, rightDuration - offset)) }
    @ObservationIgnored private var timer: Timer?
    func configure(leftURL: URL?, rightURL: URL?, leftDuration: Double, rightDuration: Double) {
        close()
        left = leftURL.map { AVPlayer(url: $0) }; right = rightURL.map { AVPlayer(url: $0) }
        left?.isMuted = true; right?.isMuted = true
        self.leftDuration = leftDuration; self.rightDuration = rightDuration
        duration = max(0, min(leftDuration, rightDuration)); time = 0; offset = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing, let left = self.left, let right = self.right else { return }
                self.time = left.currentTime().seconds
                let target = max(0, self.time + self.offset)
                if abs(right.currentTime().seconds - target) > 0.08 { right.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                if self.time >= self.availableEnd { self.pause() }
            }
        }
    }
    func toggle() {
        guard left != nil, right != nil, availableEnd > availableStart else { return }
        if playing { pause() } else {
            seek()
            let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.2, preferredTimescale: 600)
            left?.setRate(1, time: CMTime(seconds: time, preferredTimescale: 600), atHostTime: host)
            right?.setRate(1, time: CMTime(seconds: max(0, time + offset), preferredTimescale: 600), atHostTime: host)
            playing = true
        }
    }
    func pause() { left?.pause(); right?.pause(); playing = false }
    func seek() { time = min(availableEnd, max(availableStart, time)); left?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); right?.seek(to: CMTime(seconds: max(0, time + offset), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func close() { pause(); timer?.invalidate(); timer = nil; left = nil; right = nil }
}

struct ComparisonView: View {
    @Bindable var model: LiveFitViewModel
    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var playback = ComparisonPlayback()
    @State private var metric: MetricKind = .kneeFlexion
    private var before: FitSession? { model.repository.sessions.first { $0.id == beforeID } }
    private var after: FitSession? { model.repository.sessions.first { $0.id == afterID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    sessionPicker("Before", selection: $beforeID)
                    sessionPicker("After", selection: $afterID)
                }
                if let before, let after, before.id != after.id {
                    HStack {
                        comparisonVideo(player: playback.left, title: before.name)
                        comparisonVideo(player: playback.right, title: after.name)
                    }
                    HStack {
                        Button(playback.playing ? "Pause both" : "Play synchronized", systemImage: playback.playing ? "pause.fill" : "play.fill") { playback.toggle() }.disabled(playback.left == nil || playback.right == nil)
                        Slider(value: $playback.time, in: playback.availableStart...max(playback.availableStart + 0.001, playback.availableEnd), onEditingChanged: { editing in if editing { playback.pause() } else { playback.seek() } })
                        Text("\(playback.time, specifier: "%.1f") s").monospacedDigit()
                        Text("After offset (s)")
                        TextField("0", value: $playback.offset, format: .number).textFieldStyle(.roundedBorder).frame(width: 65).onChange(of: playback.offset) { _, _ in playback.pause(); playback.seek() }
                    }
                    Text("Use the time offset to align comparable pedal phases. Controls above drive both players; the timeline follows the before session. Different views or calibration can change measurements.").font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        GridRow { Text("Metric"); Text("Before mean"); Text("After mean"); Text("Δ mean"); Text("Before min / max"); Text("After min / max") }.font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(MetricKind.allCases) { kind in
                            let a = before.statistics[kind] ?? MetricStatistics(), b = after.statistics[kind] ?? MetricStatistics()
                            GridRow {
                                Text(kind.title)
                                Text(formatted(a.average, unit: kind.unit)); Text(formatted(b.average, unit: kind.unit))
                                Text(a.average.flatMap { av in b.average.map { String(format: "%+.1f", $0 - av) + kind.unit } } ?? "—").foregroundStyle(.teal)
                                Text("\(formatted(a.minimum, unit: kind.unit)) / \(formatted(a.maximum, unit: kind.unit))")
                                Text("\(formatted(b.minimum, unit: kind.unit)) / \(formatted(b.maximum, unit: kind.unit))")
                            }
                        }
                    }.monospacedDigit().padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    Text("Movement stability: side-view vertical hip motion is compared above. Lateral pelvic rocking requires a rear camera view.").font(.callout).foregroundStyle(.secondary)
                    Text("\(before.strokes.count) before strokes · \(after.strokes.count) after strokes").font(.callout)
                    Picker("Graph", selection: $metric) { ForEach(MetricKind.allCases) { Text($0.title).tag($0) } }.frame(width: 280)
                    Chart {
                        ForEach(chartData(before.samples, metric: metric)) { point in LineMark(x: .value("Time", point.time), y: .value(metric.title, point.value), series: .value("Tracking segment", "Before-\(point.segment)")).foregroundStyle(by: .value("Session", "Before")) }
                        ForEach(chartData(after.samples, metric: metric)) { point in LineMark(x: .value("Time", point.time - playback.offset), y: .value(metric.title, point.value), series: .value("Tracking segment", "After-\(point.segment)")).foregroundStyle(by: .value("Session", "After")) }
                    }.chartXAxisLabel("Seconds").chartYAxisLabel(metric.unit).frame(height: 250)
                    Text("Recorded changes in the after session").font(.title3.bold())
                    if after.adjustments.isEmpty { Text("No confirmed adjustments logged.").foregroundStyle(.secondary) }
                    ForEach(after.adjustments) { change in HStack { Text(change.step.title); Spacer(); Text("\(change.amount, specifier: "%+.1f") \(change.unit)").monospacedDigit(); Text(change.notes).foregroundStyle(.secondary) } }
                } else {
                    ContentUnavailableView("Choose two sessions", systemImage: "rectangle.split.2x1", description: Text("Save a baseline, make a measured adjustment and record a second session."))
                }
            }.padding(24)
        }
        .onAppear { beforeID = model.repository.sessions.first(where: \.isBaseline)?.id ?? model.repository.sessions.last?.id; afterID = model.repository.sessions.first(where: { $0.id != beforeID })?.id; configure() }
        .onChange(of: beforeID) { _, _ in configure() }.onChange(of: afterID) { _, _ in configure() }
        .onDisappear { playback.close() }
    }
    private func sessionPicker(_ title: String, selection: Binding<UUID?>) -> some View { Picker(title, selection: selection) { Text("Select session").tag(nil as UUID?); ForEach(model.repository.sessions) { Text($0.name + ($0.isBaseline ? " · Baseline" : "")).tag(Optional($0.id)) } } }
    private func comparisonVideo(player: AVPlayer?, title: String) -> some View { VStack(alignment: .leading) { Text(title).font(.headline); if let player { SynchronizedVideo(player: player).frame(height: 300) } else { ContentUnavailableView("No recorded video", systemImage: "video.slash").frame(height: 300) } }.frame(maxWidth: .infinity) }
    private func configure() { playback.configure(leftURL: before.flatMap { model.repository.videoURL($0) }, rightURL: after.flatMap { model.repository.videoURL($0) }, leftDuration: before?.duration ?? 0, rightDuration: after?.duration ?? 0) }
}

struct SynchronizedVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
