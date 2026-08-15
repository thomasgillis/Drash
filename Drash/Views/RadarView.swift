import MapKit
import Combine
import SwiftUI

struct RadarView: View {
    let isActive: Bool

    @EnvironmentObject private var model: WeatherViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var opacity = 0.68
    @State private var mapStyle = RadarMapStyle.standard
    @State private var refreshToken = 0
    @State private var recenterToken = 0
    @State private var showsOpacityControl = false
    @State private var showsPrecipitationLegend = false
    @State private var radarSource = RadarSource.nws
    @State private var isCheckingRadar = true
    @State private var radarError: String?
    @State private var checkedAt: Date?
    @State private var radarFrames: [RadarFrame] = []
    @State private var selectedFrameIndex = 0
    @State private var renderedFrameIndex = 0
    @State private var isScrubbingRadar = false
    @State private var isLoadingRadarFrame = false
    @State private var isPlaying = false
    @State private var lastRadarRequestToken = -1
    @State private var lastRadarRequestSource: RadarSource?
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private let fullRadarURL = URL(string: "https://radar.weather.gov/")!

    var body: some View {
        ZStack {
            if radarIsActive {
                NativeRadarMap(
                    location: radarLocation,
                    opacity: opacity,
                    mapStyle: mapStyle,
                    refreshToken: refreshToken,
                    recenterToken: recenterToken,
                    radarSource: radarSource,
                    frame: renderedRadarFrame,
                    prefetchFrames: adjacentRadarFrames,
                    isLoadingFrame: $isLoadingRadarFrame,
                    isActive: true
                )
                .accessibilityLabel(radarSource.mapAccessibilityLabel)
            } else {
                Color(.systemBackground)
            }

            VStack(spacing: 12) {
                statusCard

                if let radarError {
                    errorBanner(radarError)
                }

                Spacer()
                controlsCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .navigationTitle("Radar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { optionsMenu }
        .task(id: RadarLoadRequest(
            isActive: radarIsActive,
            refreshToken: refreshToken,
            radarSource: radarSource
        )) {
            guard radarIsActive else { return }
            await checkRadarAvailability()
        }
        .task(id: isPlaying) { await runRadarLoop() }
        .onDisappear { isPlaying = false }
        .onChange(of: isActive) { _, active in
            if !active {
                isPlaying = false
            }
        }
        .onChange(of: radarSource) { _, _ in
            isPlaying = false
            radarError = nil
            checkedAt = nil
            radarFrames = []
            selectedFrameIndex = 0
            renderedFrameIndex = 0
            isScrubbingRadar = false
            isLoadingRadarFrame = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isPlaying = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            if isLowPowerModeEnabled {
                isPlaying = false
            }
        }
    }

    private var radarIsActive: Bool {
        isActive && scenePhase == .active
    }

    private var radarLocation: WeatherLocation {
        model.snapshot?.location
            ?? model.selectedLocation
            ?? WeatherLocation(name: "United States", latitude: 39.5, longitude: -98.35)
    }

    private var statusCard: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(radarSource.statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: radarSource.statusColor.opacity(0.8), radius: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(radarSource.statusTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(radarSource.statusColor)
                Text(radarLocation.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer()

            if isCheckingRadar {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(radarSource.checkingLabel)
            } else if let checkedAt {
                Label(
                    checkedAt.formatted(date: .omitted, time: .shortened),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var controlsCard: some View {
        VStack(spacing: 12) {
            Picker("Radar source", selection: $radarSource) {
                ForEach(RadarSource.allCases) { source in
                    Text(source.shortName).tag(source)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Precipitation")
                        .font(.headline)
                        .lineLimit(1)
                    Text(frameDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    recenterToken += 1
                } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Center radar on location")

                Button {
                    refreshToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Refresh radar")
            }

            if showsPrecipitationLegend {
                precipitationLegend
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !radarFrames.isEmpty {
                radarTimeline
            }

            if showsOpacityControl {
                HStack(spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: $opacity, in: 0.25...1)
                        .accessibilityLabel("Radar opacity")
                        .accessibilityValue("\(Int(opacity * 100)) percent")
                    Text("\(Int(opacity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                Label(
                    radarSource.attribution,
                    systemImage: "checkmark.seal.fill"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var precipitationLegend: some View {
        VStack(spacing: 4) {
            LinearGradient(
                colors: [.cyan, .blue, .green, .yellow, .orange, .red, .purple],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 7)
            .clipShape(Capsule())

            HStack {
                Text("Light")
                Spacer()
                Text("Moderate")
                Spacer()
                Text("Heavy")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Precipitation intensity legend, light to heavy")
        .accessibilityIdentifier("precipitation-intensity-legend")
    }

    private var radarTimeline: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Text(radarSource.timelineTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)

                Text(selectedRadarFrame?.validTime.formatted(date: .omitted, time: .shortened) ?? "—")
                    .font(.caption.monospacedDigit().weight(.semibold))

                if isLoadingRadarFrame && !isScrubbingRadar {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Loading radar frame")
                }

                Spacer()

                Button {
                    stepRadar(by: -1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .disabled(selectedFrameIndex == 0)
                .accessibilityLabel("Previous radar frame")

                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .disabled(isLowPowerModeEnabled)
                .accessibilityLabel(isPlaying ? "Pause radar" : "Play radar")
                .accessibilityHint(
                    isLowPowerModeEnabled ? "Playback is unavailable in Low Power Mode" : ""
                )

                Button {
                    stepRadar(by: 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .disabled(selectedFrameIndex >= radarFrames.count - 1)
                .accessibilityLabel("Next radar frame")
            }
            .buttonStyle(.borderless)

            Slider(
                value: Binding(
                    get: { Double(selectedFrameIndex) },
                    set: {
                        isPlaying = false
                        selectedFrameIndex = Int($0.rounded())
                    }
                ),
                in: 0...Double(max(radarFrames.count - 1, 0)),
                step: 1,
                onEditingChanged: { isEditing in
                    isPlaying = false
                    isScrubbingRadar = isEditing
                    if !isEditing {
                        renderedFrameIndex = selectedFrameIndex
                    }
                }
            )
            .tint(.blue)
            .accessibilityLabel("Radar time")
            .accessibilityValue(radarAccessibilityValue)

            if isLowPowerModeEnabled {
                Label("Playback paused in Low Power Mode", systemImage: "battery.25percent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isScrubbingRadar {
                Label("Release to load this frame", systemImage: "hand.draw")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(radarSource.timelineStartLabel)
                Spacer()
                Text(radarSource.timelineEndLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(radarSource.timelineTitle.capitalized) radar timeline")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Radar connection unavailable")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry") { refreshToken += 1 }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ToolbarContentBuilder
    private var optionsMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Map style", selection: $mapStyle) {
                    ForEach(RadarMapStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbol).tag(style)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsOpacityControl.toggle()
                    }
                } label: {
                    Label(
                        showsOpacityControl ? "Hide opacity control" : "Adjust radar opacity",
                        systemImage: "circle.lefthalf.filled"
                    )
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsPrecipitationLegend.toggle()
                    }
                } label: {
                    Label(
                        showsPrecipitationLegend
                            ? "Hide precipitation legend"
                            : "Show precipitation legend",
                        systemImage: "paintpalette.fill"
                    )
                }

                Divider()

                Button {
                    openURL(fullRadarURL)
                } label: {
                    Label("Open full NWS viewer", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Radar options")
        }
    }

    private func checkRadarAvailability() async {
        if lastRadarRequestToken == refreshToken,
           lastRadarRequestSource == radarSource,
           let checkedAt,
           Date().timeIntervalSince(checkedAt) < 5 * 60 {
            return
        }
        lastRadarRequestToken = refreshToken
        lastRadarRequestSource = radarSource
        isCheckingRadar = true
        radarError = nil

        do {
            switch radarSource {
            case .hrrr:
                let modelRun = try await latestHRRRModelRun()
                let frames = stride(from: 0, through: 18 * 60, by: 15).map { minute in
                    RadarFrame(
                        validTime: modelRun.addingTimeInterval(TimeInterval(minute * 60)),
                        forecastMinute: minute,
                        modelInitialization: modelRun
                    )
                }
                radarFrames = frames
                let initialFrameIndex = frames.firstIndex(where: { $0.validTime >= .now })
                    ?? max(frames.count - 1, 0)
                selectedFrameIndex = initialFrameIndex
                renderedFrameIndex = initialFrameIndex
            case .nws:
                let data = try await nwsRadarCapabilities()
                let observedFrames = radarFrameTimes(from: data)
                guard !observedFrames.isEmpty else {
                    throw RadarConnectionError.invalidResponse(source: .nws)
                }
                radarFrames = observedFrames.map {
                    RadarFrame(validTime: $0, forecastMinute: nil, modelInitialization: nil)
                }
                selectedFrameIndex = observedFrames.count - 1
                renderedFrameIndex = selectedFrameIndex
            }
            checkedAt = .now
        } catch is CancellationError {
            return
        } catch {
            radarError = error.localizedDescription
        }

        isCheckingRadar = false
    }

    private func nwsRadarCapabilities() async throws -> Data {
        var request = URLRequest(url: RadarTileOverlay.nwsCapabilitiesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("Drash/1.0 (personal iOS weather app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              data.range(of: Data("conus_bref_qcd".utf8)) != nil else {
            throw RadarConnectionError.invalidResponse(source: .nws)
        }
        return data
    }

    private func latestHRRRModelRun() async throws -> Date {
        var request = URLRequest(url: RadarTileOverlay.hrrrMetadataURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("Drash/1.0 (personal iOS weather app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let metadata = try? JSONDecoder().decode(HRRRRadarMetadata.self, from: data),
              let modelRun = ISO8601DateFormatter().date(from: metadata.modelInitializationUTC) else {
            throw RadarConnectionError.invalidResponse(source: .hrrr)
        }
        return modelRun
    }

    private var selectedRadarFrame: RadarFrame? {
        guard radarFrames.indices.contains(selectedFrameIndex) else { return nil }
        return radarFrames[selectedFrameIndex]
    }

    private var renderedRadarFrame: RadarFrame? {
        guard radarFrames.indices.contains(renderedFrameIndex) else { return nil }
        return radarFrames[renderedFrameIndex]
    }

    private var adjacentRadarFrames: [RadarFrame] {
        [renderedFrameIndex + 1, renderedFrameIndex - 1]
            .filter { radarFrames.indices.contains($0) }
            .map { radarFrames[$0] }
    }

    private var latestObservedIndex: Int {
        max(radarFrames.count - 1, 0)
    }

    private var frameDescription: String {
        guard let frame = selectedRadarFrame else { return "Latest mosaic" }
        switch radarSource {
        case .hrrr:
            if frame.forecastMinute == 0 { return "Model analysis" }
            return "Simulated reflectivity · +\((frame.forecastMinute ?? 0) / 60)h \((frame.forecastMinute ?? 0) % 60)m"
        case .nws:
            if selectedFrameIndex == latestObservedIndex {
                return "Latest observed mosaic"
            }
            return "Observed at \(frame.validTime.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var radarAccessibilityValue: String {
        guard let frame = selectedRadarFrame else { return "Latest" }
        switch radarSource {
        case .hrrr:
            return "HRRR forecast valid \(frame.validTime.formatted(date: .omitted, time: .shortened))"
        case .nws:
            return "Observed \(frame.validTime.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func stepRadar(by amount: Int) {
        isPlaying = false
        let newIndex = min(
            max(selectedFrameIndex + amount, 0),
            max(radarFrames.count - 1, 0)
        )
        selectedFrameIndex = newIndex
        renderedFrameIndex = newIndex
    }

    private func runRadarLoop() async {
        guard isPlaying,
              radarIsActive,
              !isLowPowerModeEnabled,
              radarFrames.count > 1 else { return }

        while isPlaying, radarIsActive, !isLowPowerModeEnabled, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(900))
            guard isPlaying, !Task.isCancelled else { return }
            let newIndex = selectedFrameIndex >= radarFrames.count - 1
                ? 0
                : selectedFrameIndex + 1
            selectedFrameIndex = newIndex
            renderedFrameIndex = newIndex
        }
    }

    private func radarFrameTimes(from data: Data) -> [Date] {
        guard let xml = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"<(?:Dimension|Extent)\b[^>]*\bname\s*=\s*[\"']time[\"'][^>]*>([^<]+)</(?:Dimension|Extent)>"#,
                options: [.caseInsensitive]
              ),
              let match = expression.firstMatch(
                in: xml,
                range: NSRange(xml.startIndex..., in: xml)
              ),
              let valuesRange = Range(match.range(at: 1), in: xml) else { return [] }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let frames = xml[valuesRange]
            .split(separator: ",")
            .compactMap { formatter.date(from: String($0)) }
            .sorted()
        return quarterHourlyObservedFrames(from: frames)
    }

    private func quarterHourlyObservedFrames(from frames: [Date]) -> [Date] {
        guard let newest = frames.last else { return [] }
        let twoHours: TimeInterval = 2 * 60 * 60
        let quarterHour: TimeInterval = 15 * 60
        var sampled: [Date] = []

        for offset in stride(from: -twoHours, through: 0, by: quarterHour) {
            let target = newest.addingTimeInterval(offset)
            guard let nearest = frames.min(by: {
                abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target))
            }) else { continue }
            if sampled.last != nearest {
                sampled.append(nearest)
            }
        }
        return sampled
    }

}

private struct RadarLoadRequest: Hashable {
    let isActive: Bool
    let refreshToken: Int
    let radarSource: RadarSource
}

private enum RadarSource: String, CaseIterable, Identifiable, Hashable {
    case hrrr
    case nws

    var id: String { rawValue }
    var shortName: String { self == .hrrr ? "HRRR" : "NWS" }
    var statusTitle: String { self == .hrrr ? "HRRR FORECAST RADAR" : "LIVE NWS RADAR" }
    var statusColor: Color { self == .hrrr ? .purple : .green }
    var checkingLabel: String { self == .hrrr ? "Checking HRRR radar" : "Checking NWS radar" }
    var timelineTitle: String { self == .hrrr ? "HRRR FORECAST" : "OBSERVED" }
    var timelineStartLabel: String { self == .hrrr ? "Model run" : "Past 2 hours" }
    var timelineEndLabel: String { self == .hrrr ? "+18 hours" : "Latest" }
    var attribution: String {
        self == .hrrr ? "NOAA HRRR · Iowa State IEM" : "NOAA · National Weather Service"
    }
    var mapAccessibilityLabel: String {
        self == .hrrr ? "Native HRRR forecast radar map" : "Native NWS observed radar map"
    }
}

private struct RadarFrame: Hashable {
    let validTime: Date
    let forecastMinute: Int?
    let modelInitialization: Date?
}

private struct HRRRRadarMetadata: Decodable {
    let modelInitializationUTC: String

    private enum CodingKeys: String, CodingKey {
        case modelInitializationUTC = "model_init_utc"
    }
}

private enum RadarMapStyle: String, CaseIterable, Identifiable {
    case standard
    case satellite

    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Satellite" }
    var symbol: String { self == .standard ? "map" : "globe.americas.fill" }
}

private enum RadarConnectionError: LocalizedError {
    case invalidResponse(source: RadarSource)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(.hrrr):
            return "The HRRR forecast-radar service did not return a valid response."
        case .invalidResponse(.nws):
            return "The National Weather Service radar service did not return a valid response."
        }
    }
}

private struct NativeRadarMap: UIViewRepresentable {
    private static let defaultRadarSpanMeters: CLLocationDistance = 15 * 1_609.344

    let location: WeatherLocation
    let opacity: Double
    let mapStyle: RadarMapStyle
    let refreshToken: Int
    let recenterToken: Int
    let radarSource: RadarSource
    let frame: RadarFrame?
    let prefetchFrames: [RadarFrame]
    @Binding var isLoadingFrame: Bool
    let isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isPitchEnabled = false
        mapView.layoutMargins = UIEdgeInsets(top: 82, left: 8, bottom: 310, right: 8)
        mapView.preferredConfiguration = configuration(for: mapStyle)

        context.coordinator.updateLocation(location, on: mapView, animated: false)
        if isActive, frame != nil {
            context.coordinator.installRadar(
                on: mapView,
                refreshToken: refreshToken,
                opacity: opacity,
                radarSource: radarSource,
                frame: frame,
                prefetchFrames: prefetchFrames,
                isLoadingFrame: $isLoadingFrame
            )
        }
        context.coordinator.lastIsActive = isActive && frame != nil
        context.coordinator.lastMapStyle = mapStyle
        context.coordinator.lastRecenterToken = recenterToken
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if context.coordinator.lastLocationID != location.id {
            context.coordinator.updateLocation(location, on: mapView, animated: true)
        }

        if !isActive || frame == nil {
            if context.coordinator.lastIsActive {
                context.coordinator.unloadRadar(
                    from: mapView,
                    isLoadingFrame: $isLoadingFrame
                )
            }
        } else if !context.coordinator.lastIsActive
            || context.coordinator.lastRefreshToken != refreshToken
            || context.coordinator.lastRadarSource != radarSource
            || context.coordinator.lastFrame != frame {
            context.coordinator.installRadar(
                on: mapView,
                refreshToken: refreshToken,
                opacity: opacity,
                radarSource: radarSource,
                frame: frame,
                prefetchFrames: prefetchFrames,
                isLoadingFrame: $isLoadingFrame
            )
        }
        context.coordinator.lastIsActive = isActive && frame != nil

        if context.coordinator.lastRecenterToken != recenterToken {
            context.coordinator.lastRecenterToken = recenterToken
            context.coordinator.center(on: location, mapView: mapView, animated: true)
        }

        if context.coordinator.opacity != opacity {
            context.coordinator.opacity = opacity
            context.coordinator.radarRenderer?.alpha = opacity
        }

        if context.coordinator.lastMapStyle != mapStyle {
            context.coordinator.lastMapStyle = mapStyle
            mapView.preferredConfiguration = configuration(for: mapStyle)
        }
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.unloadRadar(from: mapView, isLoadingFrame: nil)
        mapView.delegate = nil
    }

    private func configuration(for style: RadarMapStyle) -> MKMapConfiguration {
        switch style {
        case .standard:
            MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        case .satellite:
            MKHybridMapConfiguration(elevationStyle: .flat)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastLocationID: UUID?
        var lastRefreshToken = -1
        var lastRecenterToken = 0
        var lastMapStyle = RadarMapStyle.standard
        var lastRadarSource: RadarSource?
        var lastFrame: RadarFrame?
        var lastIsActive = false
        var opacity = 0.68
        weak var radarRenderer: MKTileOverlayRenderer?
        private weak var pendingRadarRenderer: MKTileOverlayRenderer?
        private weak var pendingRadarOverlay: RadarTileOverlay?
        private var pendingRequestID: UUID?
        private var mapHasLoaded = false
        private var reloadRadarWhenMapLoads = false

        func installRadar(
            on mapView: MKMapView,
            refreshToken: Int,
            opacity: Double,
            radarSource: RadarSource,
            frame: RadarFrame?,
            prefetchFrames: [RadarFrame],
            isLoadingFrame: Binding<Bool>
        ) {
            if let pendingRadarOverlay {
                mapView.removeOverlay(pendingRadarOverlay)
            }

            let requestID = UUID()
            let overlay = RadarTileOverlay(
                refreshToken: refreshToken,
                radarSource: radarSource,
                frame: frame,
                prefetchFrames: prefetchFrames,
                requestID: requestID,
                onFirstTileLoaded: { [weak self, weak mapView] completedRequestID in
                    DispatchQueue.main.async {
                        guard let self, let mapView else { return }
                        self.showPendingRadar(
                            requestID: completedRequestID,
                            on: mapView,
                            isLoadingFrame: isLoadingFrame
                        )
                    }
                }
            )
            pendingRequestID = requestID
            pendingRadarOverlay = overlay
            DispatchQueue.main.async {
                isLoadingFrame.wrappedValue = true
            }
            reloadRadarWhenMapLoads = !mapHasLoaded
            mapView.addOverlay(overlay, level: .aboveRoads)
            lastRefreshToken = refreshToken
            lastRadarSource = radarSource
            lastFrame = frame
            self.opacity = opacity
        }

        private func showPendingRadar(
            requestID: UUID,
            on mapView: MKMapView,
            isLoadingFrame: Binding<Bool>
        ) {
            guard pendingRequestID == requestID,
                  let pendingRadarOverlay,
                  let pendingRadarRenderer else { return }

            pendingRadarRenderer.alpha = opacity
            mapView.overlays
                .compactMap { $0 as? RadarTileOverlay }
                .filter { $0 !== pendingRadarOverlay }
                .forEach(mapView.removeOverlay)
            radarRenderer = pendingRadarRenderer
            self.pendingRadarOverlay = nil
            self.pendingRadarRenderer = nil
            pendingRequestID = nil
            isLoadingFrame.wrappedValue = false
        }

        func unloadRadar(from mapView: MKMapView, isLoadingFrame: Binding<Bool>?) {
            radarRenderer = nil
            pendingRadarRenderer = nil
            pendingRadarOverlay = nil
            pendingRequestID = nil
            mapView.overlays
                .compactMap { $0 as? RadarTileOverlay }
                .forEach(mapView.removeOverlay)
            reloadRadarWhenMapLoads = false
            lastRadarSource = nil
            lastFrame = nil
            if let isLoadingFrame {
                DispatchQueue.main.async {
                    isLoadingFrame.wrappedValue = false
                }
            }
        }

        func updateLocation(_ location: WeatherLocation, on mapView: MKMapView, animated: Bool) {
            mapView.removeAnnotations(mapView.annotations)
            let annotation = MKPointAnnotation()
            annotation.coordinate = location.coordinate
            annotation.title = location.displayName
            mapView.addAnnotation(annotation)
            lastLocationID = location.id
            center(on: location, mapView: mapView, animated: animated)
        }

        func center(on location: WeatherLocation, mapView: MKMapView, animated: Bool) {
            let region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: NativeRadarMap.defaultRadarSpanMeters,
                longitudinalMeters: NativeRadarMap.defaultRadarSpanMeters
            )
            mapView.setRegion(region, animated: animated)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tileOverlay = overlay as? RadarTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
            if tileOverlay === pendingRadarOverlay {
                renderer.alpha = 0
                pendingRadarRenderer = renderer
            } else {
                renderer.alpha = opacity
                radarRenderer = renderer
            }
            if mapHasLoaded, reloadRadarWhenMapLoads {
                DispatchQueue.main.async { [weak self] in
                    self?.reloadInitialRadarIfReady()
                }
            }
            return renderer
        }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            mapHasLoaded = true
            reloadInitialRadarIfReady()
        }

        private func reloadInitialRadarIfReady() {
            guard reloadRadarWhenMapLoads,
                  let renderer = pendingRadarRenderer ?? radarRenderer else { return }
            reloadRadarWhenMapLoads = false
            renderer.reloadData()
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "RadarLocation"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = .systemBlue
            view.glyphImage = UIImage(systemName: "location.fill")
            view.displayPriority = .required
            return view
        }
    }
}

private final class RadarTileOverlay: MKTileOverlay {
    static let nwsCapabilitiesURL = URL(
        string: "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows?service=WMS&version=1.1.1&request=GetCapabilities"
    )!
    static let hrrrMetadataURL = URL(
        string: "https://mesonet.agron.iastate.edu/data/gis/images/4326/hrrr/refd_1080.json"
    )!

    private let refreshToken: Int
    private let radarSource: RadarSource
    private let frame: RadarFrame?
    private let prefetchFrames: [RadarFrame]
    private let requestID: UUID
    private let onFirstTileLoaded: (UUID) -> Void
    private var hasLoadedFirstTile = false
    private let firstTileLock = NSLock()
    private let webMercatorExtent = 20_037_508.342789244
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let tileCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 800
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private static let tileSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1_024 * 1_024,
            diskCapacity: 128 * 1_024 * 1_024
        )
        return URLSession(configuration: configuration)
    }()

    init(
        refreshToken: Int,
        radarSource: RadarSource,
        frame: RadarFrame?,
        prefetchFrames: [RadarFrame],
        requestID: UUID,
        onFirstTileLoaded: @escaping (UUID) -> Void
    ) {
        self.refreshToken = refreshToken
        self.radarSource = radarSource
        self.frame = frame
        self.prefetchFrames = prefetchFrames
        self.requestID = requestID
        self.onFirstTileLoaded = onFirstTileLoaded
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        // The WMS renders arbitrary bounding boxes, so retain MapKit's native maximum zoom.
        canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        tileURL(for: path, frame: frame)
    }

    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, (any Error)?) -> Void
    ) {
        let url = tileURL(for: path, frame: frame)
        Self.loadTileData(from: url) { [weak self] data, error in
            result(data, error)
            guard let self, let data, !data.isEmpty else { return }
            self.reportFirstTileLoadedIfNeeded()
            self.prefetchFrames.forEach { frame in
                Self.loadTileData(from: self.tileURL(for: path, frame: frame)) { _, _ in }
            }
        }
    }

    private func tileURL(for path: MKTileOverlayPath, frame: RadarFrame?) -> URL {
        switch radarSource {
        case .hrrr:
            return hrrrURL(for: path, frame: frame)
        case .nws:
            return nwsURL(for: path, frame: frame)
        }
    }

    private func hrrrURL(for path: MKTileOverlayPath, frame: RadarFrame?) -> URL {
        let forecastMinute = frame?.forecastMinute ?? 0
        let initialization = frame?.modelInitialization.map { modelInitializationKey(for: $0) } ?? "0"
        let layer = String(
            format: "hrrr::REFD-F%04d-%@",
            locale: Self.posixLocale,
            forecastMinute,
            initialization
        )
        var components = URLComponents(
            string: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/\(layer)/\(path.z)/\(path.x)/\(path.y).png"
        )!
        components.queryItems = [
            URLQueryItem(name: "drashRefresh", value: String(refreshToken))
        ]
        return components.url!
    }

    private func modelInitializationKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Self.posixLocale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.string(from: date)
    }

    private func nwsURL(for path: MKTileOverlayPath, frame: RadarFrame?) -> URL {
        let tileCount = pow(2.0, Double(path.z))
        let tileSpan = (webMercatorExtent * 2) / tileCount
        let minX = -webMercatorExtent + Double(path.x) * tileSpan
        let maxX = minX + tileSpan
        let maxY = webMercatorExtent - Double(path.y) * tileSpan
        let minY = maxY - tileSpan
        let bbox = [minX, minY, maxX, maxY]
            .map { String(format: "%.3f", locale: Self.posixLocale, $0) }
            .joined(separator: ",")

        var components = URLComponents(
            string: "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows"
        )!
        components.queryItems = [
            URLQueryItem(name: "service", value: "WMS"),
            URLQueryItem(name: "version", value: "1.1.1"),
            URLQueryItem(name: "request", value: "GetMap"),
            URLQueryItem(name: "layers", value: "conus_bref_qcd"),
            URLQueryItem(name: "styles", value: ""),
            URLQueryItem(name: "format", value: "image/png"),
            URLQueryItem(name: "transparent", value: "true"),
            URLQueryItem(name: "srs", value: "EPSG:3857"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "width", value: "256"),
            URLQueryItem(name: "height", value: "256"),
            URLQueryItem(name: "tiled", value: "true"),
            URLQueryItem(name: "drashRefresh", value: String(refreshToken))
        ]
        if let frameTime = frame?.validTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            components.queryItems?.append(
                URLQueryItem(name: "time", value: formatter.string(from: frameTime))
            )
        }
        return components.url!
    }

    private func reportFirstTileLoadedIfNeeded() {
        firstTileLock.lock()
        let shouldReport = !hasLoadedFirstTile
        hasLoadedFirstTile = true
        firstTileLock.unlock()
        if shouldReport {
            onFirstTileLoaded(requestID)
        }
    }

    private static func loadTileData(
        from url: URL,
        completion: @escaping (Data?, (any Error)?) -> Void
    ) {
        if let cached = tileCache.object(forKey: url as NSURL) {
            completion(cached as Data, nil)
            return
        }

        tileSession.dataTask(with: url) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data,
                  !data.isEmpty,
                  UIImage(data: data) != nil else {
                completion(nil, error ?? URLError(.cannotDecodeContentData))
                return
            }
            tileCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            completion(data, nil)
        }
        .resume()
    }

}
