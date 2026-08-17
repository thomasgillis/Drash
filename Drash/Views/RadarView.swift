import MapKit
import Combine
import SwiftUI

struct RadarView: View {
    let isActive: Bool
    let showForecast: () -> Void

    @EnvironmentObject private var model: WeatherViewModel
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var opacity = 0.68
    @State private var mapStyle = RadarMapStyle.standard
    @State private var refreshToken = 0
    @State private var recenterToken = 0
    @State private var gpsRecenterCoordinate: CLLocationCoordinate2D?
    @State private var isAwaitingGPSRecenter = false
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
    @State private var overlayGeometry = RadarOverlayGeometry()

    private let fullRadarURL = URL(string: "https://radar.weather.gov/")!

    var body: some View {
        ZStack {
            if radarIsActive {
                NativeRadarMap(
                    location: radarLocation,
                    savedPlaces: model.favoriteLocations,
                    deviceLocation: locationManager.currentLocation,
                    visibleContentInsets: radarMapVisibleContentInsets,
                    onSelectPlace: { location in
                        model.select(location)
                        showForecast()
                    },
                    opacity: opacity,
                    mapStyle: mapStyle,
                    refreshToken: refreshToken,
                    recenterToken: recenterToken,
                    gpsRecenterCoordinate: gpsRecenterCoordinate,
                    radarSource: radarSource,
                    frame: renderedRadarFrame,
                    prefetchFrames: nearbyRadarFrames,
                    animatesFrameTransitions: isPlaying,
                    isLoadingFrame: $isLoadingRadarFrame,
                    isActive: true
                )
                .accessibilityLabel(radarSource.mapAccessibilityLabel)
            } else {
                Color(.systemBackground)
            }

            VStack(spacing: 12) {
                statusCard
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: RadarOverlayGeometryPreferenceKey.self,
                                value: RadarOverlayGeometry(
                                    statusFrame: proxy.frame(in: .named(RadarMapCoordinateSpace.name))
                                )
                            )
                        }
                    }

                if let radarError {
                    errorBanner(radarError)
                }

                Spacer()
                controlsCard
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: RadarOverlayGeometryPreferenceKey.self,
                                value: RadarOverlayGeometry(
                                    controlsFrame: proxy.frame(in: .named(RadarMapCoordinateSpace.name))
                                )
                            )
                        }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            // Leave MapKit's attribution visible at the bottom edge of the map.
            .padding(.bottom, 40)
        }
        .coordinateSpace(name: RadarMapCoordinateSpace.name)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RadarOverlayGeometryPreferenceKey.self,
                    value: RadarOverlayGeometry(mapSize: proxy.size)
                )
            }
        }
        .onPreferenceChange(RadarOverlayGeometryPreferenceKey.self) { geometry in
            overlayGeometry = geometry
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
        .task(id: radarIsActive) {
            guard radarIsActive else { return }
            locationManager.requestLocation()
        }
        .task(id: AutomaticRadarRefreshContext(
            isActive: radarIsActive,
            radarSource: radarSource,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )) {
            await runAutomaticRadarRefresh()
        }
        .task(id: isPlaying) { await runRadarLoop() }
        .task(id: isScrubbingRadar) { await runRadarScrubLoop() }
        .onDisappear {
            isPlaying = false
            isScrubbingRadar = false
        }
        .onChange(of: isActive) { _, active in
            if !active {
                isPlaying = false
                isScrubbingRadar = false
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
                isScrubbingRadar = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            if isLowPowerModeEnabled {
                isPlaying = false
            }
        }
        .onReceive(locationManager.$currentLocation.compactMap { $0 }) { location in
            guard isAwaitingGPSRecenter else { return }
            isAwaitingGPSRecenter = false
            recenterRadar(on: location)
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

    private var radarMapVisibleContentInsets: UIEdgeInsets {
        guard let mapSize = overlayGeometry.mapSize,
              let statusFrame = overlayGeometry.statusFrame,
              let controlsFrame = overlayGeometry.controlsFrame,
              mapSize.height > 0,
              statusFrame.maxY < controlsFrame.minY else {
            return UIEdgeInsets(top: 80, left: 12, bottom: 372, right: 12)
        }

        let clearance: CGFloat = 12
        return UIEdgeInsets(
            top: statusFrame.maxY + clearance,
            left: 12,
            bottom: mapSize.height - controlsFrame.minY + clearance,
            right: 12
        )
    }

    private var statusCard: some View {
        Menu {
            Picker("Radar source", selection: $radarSource) {
                ForEach(RadarSource.allCases) { source in
                    Text(source.shortName).tag(source)
                }
            }
        } label: {
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

                VStack(alignment: .trailing, spacing: 4) {
                    if isCheckingRadar {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(radarSource.checkingLabel)
                    } else if let renderedRadarFrame {
                        Label(
                            renderedRadarFrame.validTime.formatted(
                                date: .omitted,
                                time: .shortened
                            ),
                            systemImage: "clock"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            radarSource == .hrrr
                                ? "Forecast valid \(renderedRadarFrame.validTime.formatted(date: .omitted, time: .shortened))"
                                : "Radar image time \(renderedRadarFrame.validTime.formatted(date: .omitted, time: .shortened))"
                        )
                    }

                    HStack(spacing: 4) {
                        Text("Source")
                        Image(systemName: "chevron.down")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .accessibilityIdentifier("radar-source-switcher")
        .accessibilityLabel("Radar source")
        .accessibilityValue(radarSource.shortName)
        .accessibilityHint("Choose NWS or HRRR radar")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var controlsCard: some View {
        VStack(spacing: 8) {
            if radarFrames.isEmpty {
                HStack {
                    Spacer()
                    radarUtilityButtons
                }
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
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var radarUtilityButtons: some View {
        HStack(spacing: 8) {
            Button {
                centerRadarOnGPS()
            } label: {
                Image(systemName: "location.fill")
                    .frame(width: 24, height: 28)
            }
            .accessibilityLabel("Center radar on GPS location")

            Button {
                refreshToken += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 28)
            }
            .accessibilityLabel("Refresh radar")
        }
        .buttonStyle(.borderless)
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
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(selectedRadarFrame?.validTime.formatted(date: .omitted, time: .shortened) ?? "—")
                    .font(.caption.monospacedDigit().weight(.semibold))

                if isLoadingRadarFrame {
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

                radarUtilityButtons
            }
            .buttonStyle(.borderless)

            Slider(
                value: Binding(
                    get: { Double(clampedRadarFrameIndex(selectedFrameIndex)) },
                    set: { value in
                        isPlaying = false
                        selectedFrameIndex = radarFrameIndex(for: value)
                    }
                ),
                in: radarSliderRange,
                step: 1,
                onEditingChanged: { isEditing in
                    isPlaying = false
                    isScrubbingRadar = isEditing
                    if !isEditing {
                        selectedFrameIndex = clampedRadarFrameIndex(selectedFrameIndex)
                        renderedFrameIndex = selectedFrameIndex
                    }
                }
            )
            .tint(.blue)
            .frame(height: 32)
            .accessibilityLabel("Radar time")
            .accessibilityValue(radarAccessibilityValue)
            .accessibilityHint("Swipe up or down to move through radar frames")

            if isLowPowerModeEnabled {
                Label("Playback paused in Low Power Mode", systemImage: "battery.25percent")
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

    private func centerRadarOnGPS() {
        isAwaitingGPSRecenter = true
        if let currentLocation = locationManager.currentLocation {
            recenterRadar(on: currentLocation)
        }
        if !locationManager.requestLocation() {
            isAwaitingGPSRecenter = false
        }
    }

    private func recenterRadar(on location: CLLocation) {
        gpsRecenterCoordinate = location.coordinate
        recenterToken += 1
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

    private func runAutomaticRadarRefresh() async {
        guard radarIsActive else { return }

        while !Task.isCancelled {
            let interval: Duration
            if isLowPowerModeEnabled {
                interval = .seconds(60 * 60)
            } else {
                interval = radarSource == .nws ? .seconds(5 * 60) : .seconds(15 * 60)
            }

            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }

            guard radarIsActive else { return }
            refreshToken += 1
        }
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

    private var nearbyRadarFrames: [RadarFrame] {
        guard radarFrames.count > 1,
              !isLowPowerModeEnabled else { return [] }
        let offsets = [-1, 1, -2, 2]
        var seenIndices = Set<Int>()

        return offsets.compactMap { offset in
            let index = (renderedFrameIndex + offset + radarFrames.count) % radarFrames.count
            guard index != renderedFrameIndex,
                  seenIndices.insert(index).inserted else { return nil }
            return radarFrames[index]
        }
    }

    private var radarSliderRange: ClosedRange<Double> {
        0...Double(max(radarFrames.count - 1, 0))
    }

    private func radarFrameIndex(for sliderValue: Double) -> Int {
        guard sliderValue.isFinite else {
            return clampedRadarFrameIndex(selectedFrameIndex)
        }
        let boundedValue = min(max(sliderValue, radarSliderRange.lowerBound), radarSliderRange.upperBound)
        return Int(boundedValue.rounded())
    }

    private func clampedRadarFrameIndex(_ index: Int) -> Int {
        min(max(index, 0), max(radarFrames.count - 1, 0))
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
        let newIndex = clampedRadarFrameIndex(selectedFrameIndex + amount)
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
            guard !isLoadingRadarFrame else { continue }
            let newIndex = selectedFrameIndex >= radarFrames.count - 1
                ? 0
                : selectedFrameIndex + 1
            selectedFrameIndex = newIndex
            renderedFrameIndex = newIndex
        }
    }

    private func runRadarScrubLoop() async {
        guard isScrubbingRadar else { return }

        while isScrubbingRadar, !Task.isCancelled {
            if !isLoadingRadarFrame, renderedFrameIndex != selectedFrameIndex {
                renderedFrameIndex = selectedFrameIndex
            }

            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
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

private enum RadarMapCoordinateSpace {
    static let name = "RadarMap"
}

private struct RadarOverlayGeometry: Equatable {
    var mapSize: CGSize?
    var statusFrame: CGRect?
    var controlsFrame: CGRect?

    mutating func merge(_ other: RadarOverlayGeometry) {
        mapSize = other.mapSize ?? mapSize
        statusFrame = other.statusFrame ?? statusFrame
        controlsFrame = other.controlsFrame ?? controlsFrame
    }
}

private struct RadarOverlayGeometryPreferenceKey: PreferenceKey {
    static let defaultValue = RadarOverlayGeometry()

    static func reduce(
        value: inout RadarOverlayGeometry,
        nextValue: () -> RadarOverlayGeometry
    ) {
        value.merge(nextValue())
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

private struct AutomaticRadarRefreshContext: Equatable {
    let isActive: Bool
    let radarSource: RadarSource
    let isLowPowerModeEnabled: Bool
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
    private static let defaultRadarSpanMeters: CLLocationDistance = 20 * 1_609.344

    let location: WeatherLocation
    let savedPlaces: [WeatherLocation]
    let deviceLocation: CLLocation?
    let visibleContentInsets: UIEdgeInsets
    let onSelectPlace: (WeatherLocation) -> Void
    let opacity: Double
    let mapStyle: RadarMapStyle
    let refreshToken: Int
    let recenterToken: Int
    let gpsRecenterCoordinate: CLLocationCoordinate2D?
    let radarSource: RadarSource
    let frame: RadarFrame?
    let prefetchFrames: [RadarFrame]
    let animatesFrameTransitions: Bool
    @Binding var isLoadingFrame: Bool
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectPlace: onSelectPlace)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isPitchEnabled = false
        mapView.layoutMargins = UIEdgeInsets(top: 82, left: 8, bottom: 8, right: 8)
        mapView.preferredConfiguration = configuration(for: mapStyle)

        context.coordinator.visibleContentInsets = visibleContentInsets
        context.coordinator.updateSavedPlaces(savedPlaces, on: mapView)
        context.coordinator.updateFallbackLocation(location, on: mapView, animated: false)
        if let deviceLocation {
            context.coordinator.hasCenteredOnDeviceLocation = true
            context.coordinator.center(
                on: deviceLocation.coordinate,
                mapView: mapView,
                animated: false
            )
        }
        if isActive, frame != nil {
            context.coordinator.installRadar(
                on: mapView,
                refreshToken: refreshToken,
                opacity: opacity,
                radarSource: radarSource,
                frame: frame,
                prefetchFrames: prefetchFrames,
                animatesTransition: animatesFrameTransitions,
                isLoadingFrame: $isLoadingFrame
            )
        }
        context.coordinator.lastIsActive = isActive && frame != nil
        context.coordinator.lastMapStyle = mapStyle
        context.coordinator.lastRecenterToken = recenterToken
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.setFrameTransitionsAnimated(
            animatesFrameTransitions,
            on: mapView
        )
        context.coordinator.onSelectPlace = onSelectPlace
        context.coordinator.visibleContentInsets = visibleContentInsets

        if context.coordinator.lastLocationID != location.id {
            context.coordinator.updateFallbackLocation(location, on: mapView, animated: true)
        }

        if !context.coordinator.hasCenteredOnDeviceLocation,
           let deviceLocation {
            context.coordinator.hasCenteredOnDeviceLocation = true
            context.coordinator.center(
                on: deviceLocation.coordinate,
                mapView: mapView,
                animated: true
            )
        }

        if context.coordinator.savedPlaces != savedPlaces {
            context.coordinator.updateSavedPlaces(savedPlaces, on: mapView)
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
                animatesTransition: animatesFrameTransitions,
                isLoadingFrame: $isLoadingFrame
            )
        }
        context.coordinator.lastIsActive = isActive && frame != nil

        if context.coordinator.lastRecenterToken != recenterToken {
            context.coordinator.lastRecenterToken = recenterToken
            if let gpsRecenterCoordinate {
                context.coordinator.hasCenteredOnDeviceLocation = true
                context.coordinator.center(
                    on: gpsRecenterCoordinate,
                    mapView: mapView,
                    animated: true
                )
            }
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
        var onSelectPlace: (WeatherLocation) -> Void
        var lastLocationID: UUID?
        var hasCenteredOnDeviceLocation = false
        var lastRefreshToken = -1
        var lastRecenterToken = 0
        var lastMapStyle = RadarMapStyle.standard
        var lastRadarSource: RadarSource?
        var lastFrame: RadarFrame?
        var lastIsActive = false
        var opacity = 0.68
        var savedPlaces: [WeatherLocation] = []
        var visibleContentInsets = UIEdgeInsets(top: 80, left: 12, bottom: 372, right: 12)
        var radarRenderer: MKTileOverlayRenderer?
        private var radarOverlay: RadarTileOverlay?
        private var pendingRadarRenderer: MKTileOverlayRenderer?
        private var pendingRadarOverlay: RadarTileOverlay?
        private var pendingRequestID: UUID?
        private var pendingTileIsReady = false
        private var pendingLoadingBinding: Binding<Bool>?
        private var pendingTransitionIsAnimated = false
        private var frameTransitionsAreAnimated = false
        private var radarTransitionID: UUID?
        private var mapHasLoaded = false
        private var reloadRadarWhenMapLoads = false

        init(onSelectPlace: @escaping (WeatherLocation) -> Void) {
            self.onSelectPlace = onSelectPlace
        }

        func installRadar(
            on mapView: MKMapView,
            refreshToken: Int,
            opacity: Double,
            radarSource: RadarSource,
            frame: RadarFrame?,
            prefetchFrames: [RadarFrame],
            animatesTransition: Bool,
            isLoadingFrame: Binding<Bool>
        ) {
            finishRadarTransition(on: mapView)
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
                onInitialTilesLoaded: { [weak self, weak mapView] completedRequestID in
                    DispatchQueue.main.async {
                        guard let self, let mapView else { return }
                        self.markPendingRadarReady(
                            requestID: completedRequestID,
                            on: mapView
                        )
                    }
                }
            )
            pendingRequestID = requestID
            pendingRadarOverlay = overlay
            pendingRadarRenderer = nil
            pendingTileIsReady = false
            pendingLoadingBinding = isLoadingFrame
            pendingTransitionIsAnimated = animatesTransition
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

        private func markPendingRadarReady(
            requestID: UUID,
            on mapView: MKMapView
        ) {
            guard pendingRequestID == requestID else { return }
            pendingTileIsReady = true
            showPendingRadarIfReady(on: mapView)
        }

        private func showPendingRadarIfReady(on mapView: MKMapView) {
            guard pendingTileIsReady,
                  let pendingRadarOverlay,
                  let pendingRadarRenderer else { return }

            let previousOverlay = radarOverlay
            let previousRenderer = radarRenderer
            let animatesTransition = pendingTransitionIsAnimated
            pendingRadarRenderer.alpha = previousRenderer == nil || !animatesTransition
                ? opacity
                : 0
            radarOverlay = pendingRadarOverlay
            radarRenderer = pendingRadarRenderer
            self.pendingRadarOverlay = nil
            self.pendingRadarRenderer = nil
            pendingRequestID = nil
            pendingTileIsReady = false
            pendingLoadingBinding?.wrappedValue = false
            pendingLoadingBinding = nil
            pendingTransitionIsAnimated = false

            guard let previousOverlay,
                  let previousRenderer else { return }
            if animatesTransition {
                transitionRadar(
                    from: previousOverlay,
                    renderer: previousRenderer,
                    to: pendingRadarRenderer,
                    on: mapView
                )
            } else {
                mapView.removeOverlay(previousOverlay)
            }
        }

        func setFrameTransitionsAnimated(_ animated: Bool, on mapView: MKMapView) {
            if frameTransitionsAreAnimated, !animated {
                finishRadarTransition(on: mapView)
            }
            frameTransitionsAreAnimated = animated
        }

        private func transitionRadar(
            from previousOverlay: RadarTileOverlay,
            renderer previousRenderer: MKTileOverlayRenderer,
            to nextRenderer: MKTileOverlayRenderer,
            on mapView: MKMapView
        ) {
            let transitionID = UUID()
            radarTransitionID = transitionID
            let stepCount = 8

            // Keep the complete frame underneath while the replacement fades in.
            for step in 1...stepCount {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(step * 25)
                ) { [weak self, weak mapView, weak previousRenderer, weak nextRenderer] in
                    guard let self,
                          let mapView,
                          let previousRenderer,
                          let nextRenderer,
                          self.radarTransitionID == transitionID else { return }

                    let progress = Double(step) / Double(stepCount)
                    nextRenderer.alpha = self.opacity * progress
                    previousRenderer.alpha = self.opacity * (1 - progress)

                    if step == stepCount {
                        self.radarTransitionID = nil
                        mapView.removeOverlay(previousOverlay)
                    }
                }
            }
        }

        private func finishRadarTransition(on mapView: MKMapView) {
            radarTransitionID = nil
            radarRenderer?.alpha = opacity
            mapView.overlays
                .compactMap { $0 as? RadarTileOverlay }
                .filter { overlay in
                    overlay !== radarOverlay && overlay !== pendingRadarOverlay
                }
                .forEach(mapView.removeOverlay)
        }

        func unloadRadar(from mapView: MKMapView, isLoadingFrame: Binding<Bool>?) {
            radarTransitionID = nil
            radarRenderer = nil
            radarOverlay = nil
            pendingRadarRenderer = nil
            pendingRadarOverlay = nil
            pendingRequestID = nil
            pendingTileIsReady = false
            pendingLoadingBinding = nil
            pendingTransitionIsAnimated = false
            frameTransitionsAreAnimated = false
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

        func updateFallbackLocation(
            _ location: WeatherLocation,
            on mapView: MKMapView,
            animated: Bool
        ) {
            lastLocationID = location.id
            guard !hasCenteredOnDeviceLocation else { return }
            center(on: location, mapView: mapView, animated: animated)
        }

        func updateSavedPlaces(_ places: [WeatherLocation], on mapView: MKMapView) {
            mapView.removeAnnotations(mapView.annotations.compactMap { $0 as? RadarPlaceAnnotation })
            mapView.addAnnotations(places.map(RadarPlaceAnnotation.init))
            savedPlaces = places
        }

        func center(on location: WeatherLocation, mapView: MKMapView, animated: Bool) {
            center(on: location.coordinate, mapView: mapView, animated: animated)
        }

        func center(
            on coordinate: CLLocationCoordinate2D,
            mapView: MKMapView,
            animated: Bool,
            deferUntilLayout: Bool = true
        ) {
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: NativeRadarMap.defaultRadarSpanMeters,
                longitudinalMeters: NativeRadarMap.defaultRadarSpanMeters
            )
            let visibleBounds = mapView.bounds.inset(by: visibleContentInsets)
            guard mapView.bounds.width > 0,
                  mapView.bounds.height > 0,
                  visibleBounds.width > 0,
                  visibleBounds.height > 0 else {
                mapView.setRegion(region, animated: animated)
                if deferUntilLayout {
                    DispatchQueue.main.async { [weak self, weak mapView] in
                        guard let self, let mapView else { return }
                        self.center(
                            on: coordinate,
                            mapView: mapView,
                            animated: animated,
                            deferUntilLayout: false
                        )
                    }
                }
                return
            }

            let screenCenter = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
            let visibleCenter = CGPoint(x: visibleBounds.midX, y: visibleBounds.midY)
            let fittedMapRect = mapView.mapRectThatFits(mapRect(for: region))
            let targetPoint = MKMapPoint(coordinate)
            let horizontalOffset = (visibleCenter.x - screenCenter.x)
                / mapView.bounds.width * fittedMapRect.width
            let verticalOffset = (visibleCenter.y - screenCenter.y)
                / mapView.bounds.height * fittedMapRect.height
            let cameraCenter = MKMapPoint(
                x: targetPoint.x - horizontalOffset,
                y: targetPoint.y - verticalOffset
            )
            let adjustedMapRect = MKMapRect(
                x: cameraCenter.x - fittedMapRect.width / 2,
                y: cameraCenter.y - fittedMapRect.height / 2,
                width: fittedMapRect.width,
                height: fittedMapRect.height
            )
            mapView.setVisibleMapRect(adjustedMapRect, animated: animated)
        }

        private func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
            let northWest = MKMapPoint(CLLocationCoordinate2D(
                latitude: region.center.latitude + region.span.latitudeDelta / 2,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            ))
            let southEast = MKMapPoint(CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            ))
            return MKMapRect(
                x: min(northWest.x, southEast.x),
                y: min(northWest.y, southEast.y),
                width: abs(southEast.x - northWest.x),
                height: abs(southEast.y - northWest.y)
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tileOverlay = overlay as? RadarTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
            if tileOverlay === pendingRadarOverlay {
                renderer.alpha = 0
                pendingRadarRenderer = renderer
                showPendingRadarIfReady(on: mapView)
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
            guard let place = annotation as? RadarPlaceAnnotation else {
                // Keep MapKit's standard blue GPS dot and accuracy ring.
                return nil
            }

            let identifier = "SavedRadarPlace"
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: identifier
            ) as? RadarPlaceAnnotationView
                ?? RadarPlaceAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.configure(for: place)
            view.onSecondTap = { [weak self] in
                self?.onSelectPlace(place.location)
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let placeView = view as? RadarPlaceAnnotationView else { return }
            placeView.setArmed(true, animated: true)
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let placeView = view as? RadarPlaceAnnotationView else { return }
            placeView.setArmed(false, animated: true)
        }
    }
}

private final class RadarPlaceAnnotation: NSObject, MKAnnotation {
    let location: WeatherLocation
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let kind: WeatherLocationKind

    init(location: WeatherLocation) {
        self.location = location
        coordinate = location.coordinate
        title = location.displayName
        subtitle = "Saved \(location.kind.markerDescription)"
        kind = location.kind
    }
}

private final class RadarPlaceAnnotationView: MKAnnotationView {
    private let glyphView = UIImageView()
    private var placeKind: WeatherLocationKind?
    private var touchBeganArmed = false
    private var touchStartPoint = CGPoint.zero
    private(set) var isArmed = false
    var onSecondTap: (() -> Void)?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1.25
        collisionMode = .circle
        displayPriority = .defaultHigh
        canShowCallout = false
        isAccessibilityElement = true
        accessibilityTraits = .button

        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.contentMode = .scaleAspectFit
        addSubview(glyphView)
        NSLayoutConstraint.activate([
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: 15),
            glyphView.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(for place: RadarPlaceAnnotation) {
        placeKind = place.kind
        setArmed(false, animated: false)
        glyphView.image = UIImage(
            systemName: place.kind.savedPlaceSymbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        accessibilityLabel = place.title
        updateAppearanceColors()
    }

    func setArmed(_ armed: Bool, animated: Bool) {
        guard isArmed != armed || !animated else { return }
        isArmed = armed
        displayPriority = armed ? .required : .defaultHigh
        accessibilityValue = armed ? "Selected" : nil
        accessibilityHint = armed
            ? "Activate again to open the forecast"
            : "Activate to select this saved place"
        let changes = {
            self.transform = armed
                ? CGAffineTransform(scaleX: 1.3, y: 1.3)
                : .identity
        }
        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: changes
            )
        } else {
            changes()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchBeganArmed = isArmed
        if let touch = touches.first {
            touchStartPoint = touch.location(in: self)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let shouldOpenForecast: Bool
        if let touch = touches.first {
            let endPoint = touch.location(in: self)
            shouldOpenForecast = touchBeganArmed
                && hypot(endPoint.x - touchStartPoint.x, endPoint.y - touchStartPoint.y) < 10
        } else {
            shouldOpenForecast = false
        }
        super.touchesEnded(touches, with: event)
        if shouldOpenForecast {
            onSecondTap?()
        }
    }

    override func accessibilityActivate() -> Bool {
        if isArmed {
            onSecondTap?()
        } else {
            setArmed(true, animated: true)
        }
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else {
            return
        }
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        guard let placeKind else { return }
        let color = placeKind.savedPlaceUIColor
        let resolvedColor = color.resolvedColor(with: traitCollection)
        layer.borderColor = resolvedColor.withAlphaComponent(0.85).cgColor
        glyphView.tintColor = color
    }
}

private extension WeatherLocationKind {
    var markerDescription: String {
        switch self {
        case .place: "city"
        case .crag: "climbing crag"
        case .summit: "summit"
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
    private let onInitialTilesLoaded: (UUID) -> Void
    private let tileLoadLock = NSLock()
    private var tileLoadsInFlight = 0
    private var successfulTileLoads = 0
    private var tileLoadGeneration = 0
    private var hasReportedInitialTiles = false
    private var initialBatchIsCached = true
    private var readinessWorkItem: DispatchWorkItem?
    private var initialTilePaths: [TilePathKey: MKTileOverlayPath] = [:]
    private let webMercatorExtent = 20_037_508.342789244
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let tileCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 500
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()
    private static let tileSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 96 * 1_024 * 1_024
        )
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()
    private static let formatterLock = NSLock()
    private static let modelInitializationCache: NSCache<NSDate, NSString> = {
        let cache = NSCache<NSDate, NSString>()
        cache.countLimit = 256
        return cache
    }()
    private static let wmsTimestampCache: NSCache<NSDate, NSString> = {
        let cache = NSCache<NSDate, NSString>()
        cache.countLimit = 256
        return cache
    }()
    private static let modelInitializationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter
    }()
    private static let wmsTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private typealias TileCompletion = (Data?, (any Error)?, Bool) -> Void
    private static let requestLock = NSLock()
    private static var inFlightRequests: [URL: InFlightTileRequest] = [:]

    private final class InFlightTileRequest {
        var completions: [TileCompletion]
        var task: URLSessionDataTask?
        var priority: Float

        init(completion: @escaping TileCompletion, priority: Float) {
            completions = [completion]
            self.priority = priority
        }
    }

    private struct TilePathKey: Hashable {
        let x: Int
        let y: Int
        let z: Int
        let scale: Int

        init(_ path: MKTileOverlayPath) {
            x = path.x
            y = path.y
            z = path.z
            scale = Int((path.contentScaleFactor * 100).rounded())
        }
    }

    init(
        refreshToken: Int,
        radarSource: RadarSource,
        frame: RadarFrame?,
        prefetchFrames: [RadarFrame],
        requestID: UUID,
        onInitialTilesLoaded: @escaping (UUID) -> Void
    ) {
        self.refreshToken = refreshToken
        self.radarSource = radarSource
        self.frame = frame
        self.prefetchFrames = prefetchFrames
        self.requestID = requestID
        self.onInitialTilesLoaded = onInitialTilesLoaded
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
        beginTileLoad(path: path)
        let url = tileURL(for: path, frame: frame)
        Self.loadTileData(from: url) { [weak self] data, error, wasCached in
            result(data, error)
            self?.finishTileLoad(
                succeeded: data?.isEmpty == false,
                wasCached: wasCached
            )
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
        let cacheKey = date as NSDate
        if let cached = Self.modelInitializationCache.object(forKey: cacheKey) {
            return cached as String
        }

        Self.formatterLock.lock()
        let value = Self.modelInitializationFormatter.string(from: date)
        Self.formatterLock.unlock()
        Self.modelInitializationCache.setObject(value as NSString, forKey: cacheKey)
        return value
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
        let displayScale = min(max(path.contentScaleFactor, 1), 2)
        let pixelDimension = Int(
            (tileSize.width * displayScale).rounded()
        )

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
            URLQueryItem(name: "width", value: String(pixelDimension)),
            URLQueryItem(name: "height", value: String(pixelDimension)),
            URLQueryItem(name: "tiled", value: "true"),
            URLQueryItem(name: "drashRefresh", value: String(refreshToken))
        ]
        if let frameTime = frame?.validTime {
            components.queryItems?.append(
                URLQueryItem(name: "time", value: wmsTimestamp(for: frameTime))
            )
        }
        return components.url!
    }

    private func wmsTimestamp(for date: Date) -> String {
        let cacheKey = date as NSDate
        if let cached = Self.wmsTimestampCache.object(forKey: cacheKey) {
            return cached as String
        }

        Self.formatterLock.lock()
        let value = Self.wmsTimestampFormatter.string(from: date)
        Self.formatterLock.unlock()
        Self.wmsTimestampCache.setObject(value as NSString, forKey: cacheKey)
        return value
    }

    private func beginTileLoad(path: MKTileOverlayPath) {
        tileLoadLock.lock()
        tileLoadsInFlight += 1
        tileLoadGeneration &+= 1
        initialTilePaths[TilePathKey(path)] = path
        let workItem = readinessWorkItem
        readinessWorkItem = nil
        tileLoadLock.unlock()
        workItem?.cancel()
    }

    private func finishTileLoad(succeeded: Bool, wasCached: Bool) {
        tileLoadLock.lock()
        tileLoadsInFlight = max(tileLoadsInFlight - 1, 0)
        initialBatchIsCached = initialBatchIsCached && wasCached
        if succeeded {
            successfulTileLoads += 1
        }

        guard tileLoadsInFlight == 0,
              successfulTileLoads > 0,
              !hasReportedInitialTiles else {
            tileLoadLock.unlock()
            return
        }

        let generation = tileLoadGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.reportInitialTilesIfSettled(generation: generation)
        }
        let quietPeriodMilliseconds = initialBatchIsCached ? 40 : 150
        readinessWorkItem = workItem
        tileLoadLock.unlock()
        // MapKit requests the visible tile grid in a burst. A short quiet period
        // prevents the first cached tile from promoting an otherwise empty frame.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(quietPeriodMilliseconds),
            execute: workItem
        )
    }

    private func reportInitialTilesIfSettled(generation: Int) {
        tileLoadLock.lock()
        guard tileLoadsInFlight == 0,
              tileLoadGeneration == generation,
              successfulTileLoads > 0,
              !hasReportedInitialTiles else {
            tileLoadLock.unlock()
            return
        }
        hasReportedInitialTiles = true
        readinessWorkItem = nil
        let paths = Array(initialTilePaths.values)
        tileLoadLock.unlock()
        onInitialTilesLoaded(requestID)
        prefetchNearbyFrames(at: paths)
    }

    private func prefetchNearbyFrames(at paths: [MKTileOverlayPath]) {
        guard !paths.isEmpty, !prefetchFrames.isEmpty else { return }

        for frame in prefetchFrames {
            for path in paths {
                let url = tileURL(for: path, frame: frame)
                Self.loadTileData(
                    from: url,
                    priority: URLSessionTask.lowPriority
                ) { _, _, _ in }
            }
        }
    }

    private static func loadTileData(
        from url: URL,
        priority: Float = URLSessionTask.highPriority,
        completion: @escaping TileCompletion
    ) {
        if let cached = tileCache.object(forKey: url as NSURL) {
            completion(cached as Data, nil, true)
            return
        }

        requestLock.lock()
        if let request = inFlightRequests[url] {
            request.completions.append(completion)
            request.priority = max(request.priority, priority)
            request.task?.priority = request.priority
            requestLock.unlock()
            return
        }
        inFlightRequests[url] = InFlightTileRequest(
            completion: completion,
            priority: priority
        )
        requestLock.unlock()

        fetchTileData(from: url, retriesRemaining: 1)
    }

    private static func fetchTileData(from url: URL, retriesRemaining: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let task = tileSession.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data,
                  !data.isEmpty,
                  data.prefix(Self.pngSignature.count) == Self.pngSignature else {
                if retriesRemaining > 0 {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + .milliseconds(150)
                    ) {
                        fetchTileData(
                            from: url,
                            retriesRemaining: retriesRemaining - 1
                        )
                    }
                } else {
                    finishTileRequest(
                        for: url,
                        data: nil,
                        error: error ?? URLError(.cannotDecodeContentData)
                    )
                }
                return
            }
            tileCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            finishTileRequest(for: url, data: data, error: nil)
        }

        requestLock.lock()
        guard let inFlightRequest = inFlightRequests[url] else {
            requestLock.unlock()
            return
        }
        inFlightRequest.task = task
        task.priority = inFlightRequest.priority
        requestLock.unlock()
        task.resume()
    }

    private static func finishTileRequest(
        for url: URL,
        data: Data?,
        error: (any Error)?
    ) {
        requestLock.lock()
        let completions = inFlightRequests.removeValue(forKey: url)?.completions ?? []
        requestLock.unlock()
        completions.forEach { $0(data, error, false) }
    }

}
