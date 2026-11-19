import QuickBounceDomain
import SwiftUI

enum DisplayedAudioMetric: String, CaseIterable, Identifiable {
    case samplePeak
    case truePeak
    case maxMomentary
    case maxShortTerm
    case integrated
    case loudnessRange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .samplePeak: "Sample Peak"
        case .truePeak: "True Peak"
        case .maxMomentary: "Max. Momentary Loudness"
        case .maxShortTerm: "Max. Short-Term Loudness"
        case .integrated: "Integrated Loudness"
        case .loudnessRange: "Loudness Range"
        }
    }

    var shortLabel: String {
        switch self {
        case .samplePeak: "SP"
        case .truePeak: "TP"
        case .maxMomentary: "Max M"
        case .maxShortTerm: "Max S"
        case .integrated: "I"
        case .loudnessRange: "LRA"
        }
    }

    var unit: String {
        switch self {
        case .samplePeak: "dBFS"
        case .truePeak: "dBTP"
        case .maxMomentary, .maxShortTerm, .integrated: "LUFS"
        case .loudnessRange: "LU"
        }
    }

    var helpText: String {
        switch self {
        case .samplePeak:
            "Maximum absolute sample across every channel"
        case .truePeak:
            "Maximum reconstructed 4× true peak across every channel"
        case .maxMomentary:
            "Maximum 400 ms momentary loudness"
        case .maxShortTerm:
            "Maximum 3 second short-term loudness"
        case .integrated:
            "Integrated program loudness"
        case .loudnessRange:
            "Program loudness range"
        }
    }

    func value(from metrics: AudioMetrics?) -> Double? {
        switch self {
        case .samplePeak: metrics?.samplePeakDBFS
        case .truePeak: metrics?.truePeakDBTP
        case .maxMomentary: metrics?.maxMomentaryLUFS
        case .maxShortTerm: metrics?.maxShortTermLUFS
        case .integrated: metrics?.integratedLUFS
        case .loudnessRange: metrics?.loudnessRangeLU
        }
    }

    static var defaultPreference: String {
        allCases.map(\.rawValue).joined(separator: ",")
    }

    static func decodePreference(_ value: String) -> Set<Self> {
        Set(value.split(separator: ",").compactMap { Self(rawValue: String($0)) })
    }

    static func encodePreference(_ metrics: Set<Self>) -> String {
        allCases.filter(metrics.contains).map(\.rawValue).joined(separator: ",")
    }
}

struct MiniWaveform: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let pyramid: WaveformPyramid?
    let color: Color

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let pixelWidth = max(1, Int(ceil(size.width * displayScale)))
            guard let base = pyramid?.levels.first,
                  let envelope = pyramid?.bestLevel(
                    forVisibleFrames: base.frameCount,
                    pixelWidth: pixelWidth
                  ) else {
                var placeholder = Path()
                placeholder.move(to: CGPoint(x: 0, y: size.height / 2))
                placeholder.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    placeholder,
                    with: .color(.secondary.opacity(0.25)),
                    lineWidth: 1 / max(1, displayScale)
                )
                return
            }
            let duration = Double(envelope.frameCount) / envelope.sampleRate
            let columns = envelope.combinedPixelColumns(
                viewportStart: 0,
                viewportDuration: duration,
                pixelWidth: pixelWidth
            )
            WaveformDrawing.drawEnvelope(
                context: &context,
                size: size,
                columns: columns,
                centerY: size.height / 2,
                amplitude: size.height * 0.46,
                color: color,
                displayScale: displayScale
            )
        }
        .accessibilityHidden(true)
    }
}

struct ReviewWaveformRow: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let artifact: AudioArtifact
    let pyramid: WaveformPyramid?
    let playbackClock: ReviewPlaybackClock
    let viewportStart: Double
    let viewportDuration: Double
    let mode: ReviewMode
    let audible: Bool
    let stemState: StemPlaybackState
    let visibleMetrics: Set<DisplayedAudioMetric>
    let selectMix: () -> Void
    let solo: () -> Void
    let mute: () -> Void
    let seek: (Double) -> Void
    let analysisError: String?
    let retryAnalysis: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    titleAndControls
                    Spacer(minLength: 8)
                    metricsSummary
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleAndControls
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer(minLength: 0)
                        metricsSummary
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            if let pyramid {
                MultiChannelWaveform(
                    channelNames: artifact.channelNames,
                    pyramid: pyramid,
                    playbackClock: playbackClock,
                    showsPlayhead: mode == .stemsCheck || audible,
                    viewportStart: mode == .mixCompare ? 0 : viewportStart,
                    viewportDuration: mode == .mixCompare ? fullDuration : viewportDuration,
                    seek: seek
                )
                    .frame(height: CGFloat(max(1, pyramid.levels.first?.channels.count ?? 1)) * 58)
                if mode == .mixCompare {
                    WaveformTimeRuler(duration: fullDuration)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            } else if analysisError == nil {
                VStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(L("Preparing waveform…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 82)
            }
            if let analysisError {
                VStack(spacing: 6) {
                    Text(L("Analysis could not finish"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Retry Analysis"), action: retryAnalysis)
                        .help(L(UserFacingError.message(for: "Review analysis \(artifact.name): \(analysisError)")))
                }
                .frame(maxWidth: .infinity, minHeight: 70)
            }
        }
        .background(
            audible && mode == .mixCompare
                ? Color.accentColor.opacity(0.08)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(audible && mode == .mixCompare ? Color.cyan.opacity(0.65) : Color.secondary.opacity(0.18))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .mixCompare { selectMix() }
        }
    }

    private var titleAndControls: some View {
        HStack(spacing: 9) {
            if mode == .mixCompare {
                Button(action: selectMix) {
                    Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash")
                        .foregroundStyle(audible ? Color.cyan : .secondary)
                }
                .buttonStyle(.plain)
                .functionTip(audible ? "This Mix is audible" : "Listen to this Mix")
            } else {
                Button(L("S"), action: solo)
                    .buttonStyle(StemButtonStyle(active: stemState.isSolo, color: .yellow))
                    .functionTip("Solo stem")
                Button(L("M"), action: mute)
                    .buttonStyle(StemButtonStyle(active: stemState.isMuted, color: .red))
                    .functionTip("Mute stem")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L(formatSummary))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var metricsSummary: some View {
        MetricsSummary(metrics: artifact.metrics, visibleMetrics: visibleMetrics)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var fullDuration: Double {
        if let level = pyramid?.levels.first, level.sampleRate > 0 {
            return Double(level.frameCount) / level.sampleRate
        }
        return artifact.durationSeconds ?? 0
    }

    private var formatSummary: String {
        let rate = artifact.sampleRate.map { String(format: "%.1f kHz", $0 / 1_000) } ?? "— kHz"
        let channels = artifact.channelCount.map { "\($0) ch" } ?? "— ch"
        return "\(rate) · \(channels)"
    }
}

private struct StemButtonStyle: ButtonStyle {
    let active: Bool
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.bold())
            .frame(width: 24, height: 24)
            .background(active ? color : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(active ? Color.black : Color.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct MetricsSummary: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let metrics: AudioMetrics?
    let visibleMetrics: Set<DisplayedAudioMetric>

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DisplayedAudioMetric.allCases.filter(visibleMetrics.contains)) { metric in
                Metric(
                    label: metric.shortLabel,
                    name: metric.title,
                    value: db(metric.value(from: metrics)),
                    unit: metric.unit
                )
            }
        }
    }

    private func db(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
}

private struct Metric: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let label: String
    let name: String
    let value: String
    let unit: String

    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(L(label))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .onHover { isShowingDetails = $0 }
                .popover(
                    isPresented: $isShowingDetails,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L(name))
                            .font(.caption.weight(.semibold))
                        Text(L("\(value) \(unit)"))
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .fixedSize()
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(L(name)), \(value) \(unit)")
    }
}

struct MultiChannelWaveform: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let channelNames: [String]?
    let pyramid: WaveformPyramid
    let playbackClock: ReviewPlaybackClock
    let showsPlayhead: Bool
    let viewportStart: Double
    let viewportDuration: Double
    let seek: (Double) -> Void

    private let channelColors: [Color] = [.cyan, .pink, .green, .orange, .purple, .mint, .yellow, .blue]
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let base = pyramid.levels.first
            let sampleRate = base?.sampleRate ?? 1
            let fileDuration = Double(base?.frameCount ?? 0) / max(1, sampleRate)
            let visibleDuration = viewportDuration > 0 ? viewportDuration : fileDuration
            let visibleFrames = Int64(max(0, visibleDuration) * max(1, sampleRate))
            let pixelWidth = max(1, Int(ceil(proxy.size.width * displayScale)))
            let level = pyramid.bestLevel(
                forVisibleFrames: visibleFrames,
                pixelWidth: pixelWidth
            )
            ZStack(alignment: .topLeading) {
                if let level {
                    WaveformEnvelopeCanvas(
                        envelope: level,
                        renderRevision: pyramid.renderRevision,
                        viewportStart: viewportStart,
                        viewportDuration: visibleDuration,
                        displayScale: displayScale
                    )
                    .equatable()
                }
                if showsPlayhead {
                    SmoothWaveformPlayhead(
                        clock: playbackClock,
                        enabled: true,
                        viewportStart: viewportStart,
                        viewportDuration: visibleDuration
                    )
                }
            }
            .overlay(alignment: .topLeading) {
                channelLabels(count: level?.channels.count ?? 0, height: proxy.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard proxy.size.width > 0, visibleDuration > 0 else { return }
                        let x = min(proxy.size.width, max(0, value.location.x))
                        let fraction = Double(x / proxy.size.width)
                        seek(viewportStart + fraction * visibleDuration)
                    }
            )
            .functionTip("Seek")
        }
        .background(Color.black.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding([.horizontal, .bottom], 8)
    }

    @ViewBuilder
    private func channelLabels(count: Int, height: CGFloat) -> some View {
        if count > 0 {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Text(channelName(index, count: count))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(channelColors[index % channelColors.count])
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(4)
                }
            }
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }

    private func channelName(_ index: Int, count: Int) -> String {
        if let channelNames, channelNames.count == count { return channelNames[index] }
        if count == 1 { return "M" }
        if count == 2 { return index == 0 ? "L" : "R" }
        return "CH \(index + 1)"
    }

}

private struct WaveformEnvelopeCanvas: View, Equatable {
    let envelope: WaveformEnvelope
    let renderRevision: UUID
    let viewportStart: Double
    let viewportDuration: Double
    let displayScale: CGFloat

    private let channelColors: [Color] = [.cyan, .pink, .green, .orange, .purple, .mint, .yellow, .blue]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.envelope.artifactID == rhs.envelope.artifactID
            && lhs.renderRevision == rhs.renderRevision
            && lhs.envelope.blockSize == rhs.envelope.blockSize
            && lhs.envelope.frameCount == rhs.envelope.frameCount
            && lhs.envelope.channels.count == rhs.envelope.channels.count
            && lhs.viewportStart == rhs.viewportStart
            && lhs.viewportDuration == rhs.viewportDuration
            && lhs.displayScale == rhs.displayScale
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let pixelWidth = max(1, Int(ceil(size.width * displayScale)))
            WaveformDrawing.drawGrid(
                context: &context,
                size: size,
                channels: envelope.channels.count,
                displayScale: displayScale
            )
            for channelIndex in envelope.channels.indices {
                let columns = envelope.pixelColumns(
                    channel: channelIndex,
                    viewportStart: viewportStart,
                    viewportDuration: viewportDuration,
                    pixelWidth: pixelWidth
                )
                let channelHeight = size.height / CGFloat(max(1, envelope.channels.count))
                WaveformDrawing.drawEnvelope(
                    context: &context,
                    size: size,
                    columns: columns,
                    centerY: channelHeight * (CGFloat(channelIndex) + 0.5),
                    amplitude: channelHeight * 0.43,
                    color: channelColors[channelIndex % channelColors.count],
                    displayScale: displayScale
                )
            }
        }
    }
}

private enum WaveformDrawing {
    static func drawGrid(
        context: inout GraphicsContext,
        size: CGSize,
        channels: Int,
        displayScale: CGFloat
    ) {
        let count = max(1, channels)
        let hairline = 1 / max(1, displayScale)
        for channel in 0...count {
            let y = size.height * CGFloat(channel) / CGFloat(count)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                path,
                with: .color(.secondary.opacity(channel == 0 || channel == count ? 0.2 : 0.13)),
                lineWidth: hairline
            )
        }
        for channel in 0..<count {
            let y = size.height * (CGFloat(channel) + 0.5) / CGFloat(count)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.secondary.opacity(0.08)), lineWidth: hairline)
        }
        for division in 1..<8 {
            let x = size.width * CGFloat(division) / 8
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.secondary.opacity(0.07)), lineWidth: hairline)
        }
    }

    static func drawEnvelope(
        context: inout GraphicsContext,
        size: CGSize,
        columns: [WaveformLevel],
        centerY: CGFloat,
        amplitude: CGFloat,
        color: Color,
        displayScale: CGFloat
    ) {
        guard !columns.isEmpty, size.width > 0 else { return }
        var fill = Path()
        var upper = Path()
        var lower = Path()

        for index in columns.indices {
            let point = CGPoint(
                x: (CGFloat(index) + 0.5) / CGFloat(columns.count) * size.width,
                y: centerY - normalized(columns[index].maximum) * amplitude
            )
            if index == columns.startIndex {
                fill.move(to: point)
                upper.move(to: point)
            } else {
                fill.addLine(to: point)
                upper.addLine(to: point)
            }
        }
        for index in columns.indices.reversed() {
            let point = CGPoint(
                x: (CGFloat(index) + 0.5) / CGFloat(columns.count) * size.width,
                y: centerY - normalized(columns[index].minimum) * amplitude
            )
            fill.addLine(to: point)
            if index == columns.index(before: columns.endIndex) {
                lower.move(to: point)
            } else {
                lower.addLine(to: point)
            }
        }
        fill.closeSubpath()

        context.fill(fill, with: .color(color.opacity(0.30)))
        let hairline = 1 / max(1, displayScale)
        context.stroke(upper, with: .color(color.opacity(0.96)), lineWidth: hairline)
        context.stroke(lower, with: .color(color.opacity(0.96)), lineWidth: hairline)
    }

    private static func normalized(_ sample: Float) -> CGFloat {
        CGFloat(min(1, max(-1, sample)))
    }
}

private struct SmoothWaveformPlayhead: View {
    @ObservedObject var clock: ReviewPlaybackClock
    let enabled: Bool
    let viewportStart: Double
    let viewportDuration: Double

    @Environment(\.displayScale) private var displayScale
    @State private var anchorPosition: Double
    @State private var anchorDate = Date()
    @State private var isVisible = false

    private var isPlaying: Bool { enabled && clock.sample.isPlaying }
    private var reportedPosition: Double { enabled ? clock.sample.position : -1 }

    init(
        clock: ReviewPlaybackClock,
        enabled: Bool,
        viewportStart: Double,
        viewportDuration: Double
    ) {
        self.clock = clock
        self.enabled = enabled
        self.viewportStart = viewportStart
        self.viewportDuration = viewportDuration
        _anchorPosition = State(initialValue: enabled ? clock.sample.position : -1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying || !isVisible)) { timeline in
            GeometryReader { proxy in
                let elapsed = isPlaying ? max(0, timeline.date.timeIntervalSince(anchorDate)) : 0
                let position = anchorPosition + elapsed
                let fraction = viewportDuration > 0
                    ? (position - viewportStart) / viewportDuration
                    : -1
                if (0...1).contains(fraction) {
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: max(1 / max(1, displayScale), 0.75))
                        .position(
                            x: proxy.size.width * CGFloat(fraction),
                            y: proxy.size.height / 2
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            anchorPosition = reportedPosition
            anchorDate = Date()
            isVisible = true
        }
        .onDisappear { isVisible = false }
        .onChange(of: reportedPosition) { _, newValue in
            synchronize(to: newValue)
        }
        .onChange(of: isPlaying) { _, _ in
            anchorPosition = reportedPosition
            anchorDate = Date()
        }
        .accessibilityHidden(true)
    }

    private func synchronize(to position: Double) {
        let now = Date()
        let projected = anchorPosition + (isPlaying ? max(0, now.timeIntervalSince(anchorDate)) : 0)
        // The audio engine remains authoritative. Ignore tiny polling jitter so
        // the display-link interpolation does not step backwards every 50 ms;
        // seeks and meaningful drift corrections still snap to the real time.
        guard !isPlaying || abs(position - projected) > 0.02 else { return }
        anchorPosition = position
        anchorDate = now
    }
}

/// Each label uses the row's own duration, independent of the active Mix.
private struct WaveformTimeRuler: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let duration: Double
    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<5) { index in
                let fraction = Double(index) / 4
                Rectangle().fill(.secondary.opacity(0.35))
                    .frame(width: 1, height: 3)
                    .position(x: proxy.size.width * fraction, y: 1.5)
                Text(label(duration * fraction))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60)
                    .position(x: min(max(30, proxy.size.width * fraction), proxy.size.width - 30), y: 10)
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Full duration \(label(duration))"))
    }
    private func label(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        return String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
