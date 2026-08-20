import Charts
import SwiftUI
import UIKit

struct ForecastView: View {
    @EnvironmentObject private var model: WeatherViewModel
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedAlert: WeatherAlert?

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if isSwitchingPlaces {
                ProgressView("Loading \(model.selectedLocation?.displayName ?? "forecast")…")
                    .tint(ForecastPalette.blue)
                    .foregroundStyle(ForecastPalette.ink)
            } else if let snapshot = model.snapshot {
                GeometryReader { proxy in
                    let usesWideLayout = proxy.size.width >= 900

                    ScrollView {
                        forecastContent(snapshot, usesWideLayout: usesWideLayout)
                            .frame(maxWidth: usesWideLayout ? 1_100 : 760)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, usesWideLayout ? 24 : 16)
                            .padding(.vertical, 16)
                    }
                    .environment(\.timeZone, snapshot.location.timeZone)
                    .accessibilityIdentifier("forecast-scroll-view")
                    .refreshable {
                        // Finish the native refresh transaction immediately so its
                        // pulled-down offset is not preserved while networking runs.
                        // The view model's loading indicator reports that work instead.
                        model.refresh()
                    }
                }
            } else if model.isLoading {
                ProgressView(model.loadingDescription)
                    .tint(ForecastPalette.blue)
                    .foregroundStyle(ForecastPalette.ink)
            } else {
                EmptyWeatherView(message: model.errorMessage ?? locationManager.locationError)
            }

            if model.isLoading, model.snapshot != nil, !isSwitchingPlaces {
                VStack {
                    ProgressView()
                        .tint(ForecastPalette.blue)
                        .padding(8)
                        .background(ForecastPalette.card, in: Circle())
                        .overlay(Circle().stroke(ForecastPalette.cardBorder))
                        .shadow(color: ForecastPalette.shadow, radius: 8, y: 3)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle(model.snapshot?.location.displayName ?? "Drash")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let location = model.snapshot?.location,
                   !location.isCurrentLocation {
                    Button {
                        model.toggleFavorite(location)
                    } label: {
                        Image(systemName: model.isFavorite(location) ? "star.fill" : "star")
                    }
                    .accessibilityLabel(model.isFavorite(location) ? "Saved place" : "Save place")
                }
            }
        }
        .sheet(item: $selectedAlert) { AlertDetailView(alert: $0) }
        .alert("Couldn’t update weather", isPresented: Binding(
            get: { model.errorMessage != nil && model.snapshot != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("Retry Now") { model.forceRefreshNow() }
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func forecastContent(
        _ snapshot: WeatherSnapshot,
        usesWideLayout: Bool
    ) -> some View {
        let activeHourlyPeriods = snapshot.hourly
            .filter { $0.endTime > Date.now }
            .sorted { $0.startTime < $1.startTime }
        let rollingHourlyPeriods = Array(activeHourlyPeriods.prefix(24))
        let rawHourlyAmounts = snapshot.precipitationAmounts ?? []
        let expectedHourlyAmounts = PrecipitationVolumeRepresentation.expected.presentedAmounts(
            rawHourlyAmounts,
            probabilityPeriods: snapshot.hourly
        )
        let hourlyAmounts = model.precipitationVolumeRepresentation.presentedAmounts(
            rawHourlyAmounts,
            probabilityPeriods: snapshot.hourly
        )
        let rawDailyAmounts = snapshot.dailyPrecipitationAmounts
            ?? snapshot.precipitationAmounts
            ?? []
        let dailyProbabilityPeriods = snapshot.location.forecastModel
            == snapshot.effectiveHourlyForecastModel
            ? snapshot.hourly + snapshot.daily
            : snapshot.daily
        let expectedDailyAmounts = PrecipitationVolumeRepresentation.expected.presentedAmounts(
            rawDailyAmounts,
            probabilityPeriods: dailyProbabilityPeriods
        )
        let dailyAmounts = model.precipitationVolumeRepresentation.presentedAmounts(
            rawDailyAmounts,
            probabilityPeriods: dailyProbabilityPeriods
        )

        LazyVStack(spacing: 16) {
            if usesWideLayout {
                HStack(alignment: .top, spacing: 16) {
                    LazyVStack(spacing: 16) {
                        currentConditions(snapshot)
                        alertBanners(snapshot)
                    }
                    .frame(maxWidth: .infinity)

                    ConditionsGrid(
                        snapshot: snapshot,
                        unit: model.temperatureUnit,
                        altitudeUnit: model.altitudeUnit
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                currentConditions(snapshot)
                alertBanners(snapshot)
            }

            HourlyForecastCard(
                periods: rollingHourlyPeriods,
                precipitationAmounts: hourlyAmounts,
                rawPrecipitationAmounts: rawHourlyAmounts,
                expectedPrecipitationAmounts: expectedHourlyAmounts,
                unit: model.temperatureUnit,
                forecastModel: snapshot.effectiveHourlyForecastModel,
                precipitationVolumeRepresentation: model.precipitationVolumeRepresentation
            )
            DailyForecastCard(
                periods: snapshot.daily,
                hourlyPeriods: snapshot.hourly,
                hourlyPrecipitationAmounts: hourlyAmounts,
                rawHourlyPrecipitationAmounts: rawHourlyAmounts,
                expectedHourlyPrecipitationAmounts: expectedHourlyAmounts,
                dailyPrecipitationAmounts: dailyAmounts,
                rawDailyPrecipitationAmounts: rawDailyAmounts,
                expectedDailyPrecipitationAmounts: expectedDailyAmounts,
                unit: model.temperatureUnit,
                altitudeUnit: model.altitudeUnit,
                location: snapshot.location,
                forecastModel: snapshot.location.forecastModel,
                hourlyForecastModel: snapshot.effectiveHourlyForecastModel,
                precipitationVolumeRepresentation: model.precipitationVolumeRepresentation,
                selectedForecastModel: model.selectedForecastModel,
                isLoading: model.isLoading,
                onSelectForecastModel: model.selectForecastModel
            )

            if !usesWideLayout {
                ConditionsGrid(
                    snapshot: snapshot,
                    unit: model.temperatureUnit,
                    altitudeUnit: model.altitudeUnit
                )
            }

            Text(forecastAttribution(for: snapshot))
                .font(.caption)
                .foregroundStyle(ForecastPalette.secondary)
                .padding(.vertical, 10)
        }
    }

    private func currentConditions(_ snapshot: WeatherSnapshot) -> some View {
        CurrentConditionsCard(
            snapshot: snapshot,
            unit: model.temperatureUnit,
            didLastRefreshFail: model.didLastRefreshFail
        )
    }

    @ViewBuilder
    private func alertBanners(_ snapshot: WeatherSnapshot) -> some View {
        ForEach(snapshot.alerts) { alert in
            AlertBanner(alert: alert)
                .onTapGesture { selectedAlert = alert }
        }
        if !snapshot.alertsAreAvailable {
            AlertAvailabilityBanner()
        }
    }

    private var background: LinearGradient {
        let isNight = model.snapshot?.hourly.first?.isDaytime == false
        let colors: [Color]
        if colorScheme == .dark {
            colors = isNight
                ? [Color(red: 0.025, green: 0.035, blue: 0.08), Color(red: 0.07, green: 0.09, blue: 0.18)]
                : [Color(red: 0.025, green: 0.075, blue: 0.11), Color(red: 0.055, green: 0.15, blue: 0.21)]
        } else {
            colors = isNight
                ? [Color(red: 0.91, green: 0.92, blue: 0.99), Color(red: 0.78, green: 0.83, blue: 0.96)]
                : [Color(red: 0.94, green: 0.98, blue: 1), Color(red: 0.73, green: 0.89, blue: 0.97)]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var isSwitchingPlaces: Bool {
        guard model.isLoading,
              let selected = model.selectedLocation,
              let displayed = model.snapshot?.location else { return false }
        return abs(selected.latitude - displayed.latitude) >= 0.001
            || abs(selected.longitude - displayed.longitude) >= 0.001
    }

    private func forecastAttribution(for snapshot: WeatherSnapshot) -> String {
        let hourlyModel = snapshot.effectiveHourlyForecastModel
        let dailyModel = snapshot.location.forecastModel
        let hourlySource = hourlyModel == .hrrr ? "NOAA HRRR via Open-Meteo" : "NWS"
        let dailySource = dailyModel == .hrrr ? "NOAA HRRR via Open-Meteo" : "NWS"
        var attribution = hourlyModel == dailyModel
            ? "Current, 24-hour, and daily forecast from \(hourlySource)"
            : "Current and 24-hour forecast from \(hourlySource) · Daily forecast from \(dailySource)"

        if snapshot.location.kind == .summit,
           let elevation = snapshot.location.elevation {
            let formattedElevation = elevation.formatted(for: model.altitudeUnit)
            if hourlyModel == .hrrr || dailyModel == .hrrr {
                attribution += " · HRRR downscaled to \(formattedElevation)"
            }
            if hourlyModel == .nws || dailyModel == .nws {
                attribution += " · NWS temperatures adjusted to \(formattedElevation)"
            }
        }
        return attribution + " · NWS alerts"
    }
}

private struct EmptyWeatherView: View {
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var model: WeatherViewModel
    let message: String?

    var body: some View {
        ContentUnavailableView {
            Label("Your weather, clearly", systemImage: "cloud.sun.fill")
        } description: {
            Text(message ?? "Use your location or add a U.S. place to get started.")
        } actions: {
            if model.selectedLocation != nil {
                Button("Retry Now") { model.forceRefreshNow() }
                    .buttonStyle(.borderedProminent)
                Button("Use My Location") { locationManager.requestLocation() }
                    .buttonStyle(.bordered)
            } else {
                Button("Use My Location") { locationManager.requestLocation() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(ForecastPalette.ink)
    }
}

private struct CurrentConditionsCard: View {
    let snapshot: WeatherSnapshot
    let unit: TemperatureUnit
    let didLastRefreshFail: Bool

    private var currentObservation: WeatherObservation? {
        snapshot.observationModel == snapshot.effectiveHourlyForecastModel
            ? snapshot.observation
            : nil
    }

    private var currentTemperature: Int? {
        if snapshot.effectiveHourlyForecastModel == .hrrr {
            return snapshot.hrrrCurrentTemperature?.temperature(in: unit)
                ?? currentObservation?.temperature.temperature(in: unit)
                ?? snapshot.hourly.first?.temperature(in: unit)
        }
        return currentObservation?.temperature.temperature(in: unit)
            ?? snapshot.hourly.first?.temperature(in: unit)
    }

    private var currentDescription: String {
        currentObservation?.displayDescription
            ?? snapshot.hourly.first?.shortForecast
            ?? "Current conditions"
    }

    private var currentWind: String? {
        currentObservation?.windSpeed.milesPerHour.map { String(format: "%.0f mph", $0) }
            ?? snapshot.hourly.first?.windSpeed
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: snapshot.hourly.first?.symbolName ?? "cloud.sun.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        snapshot.hourly.first?.weatherTint ?? ForecastPalette.secondary,
                        snapshot.hourly.first?.weatherSecondaryTint ?? ForecastPalette.blue,
                        snapshot.hourly.first?.weatherTertiaryTint ?? ForecastPalette.blue
                    )
                    .font(.system(size: 76))
                    .frame(width: 86, height: 82)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTemperature.map { "\($0)°" } ?? "—")
                        .font(.system(size: 64, weight: .thin, design: .rounded))
                        .contentTransition(.numericText())
                    Text(currentDescription)
                        .font(.headline)
                }
                Spacer()
            }

            HStack {
                if let currentHour = snapshot.hourly.first {
                    Label("\(currentHour.precipitationChance)%", systemImage: "drop.fill")
                    Spacer()
                    Label(currentWind ?? currentHour.windSpeed, systemImage: "wind")
                    Spacer()
                    HStack(spacing: 4) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(
                                "Updated \(snapshot.updatedAt.relativeUpdateDescription(relativeTo: context.date))"
                            )
                        }
                        if didLastRefreshFail {
                            Text("· Failed to update")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(ForecastPalette.secondary)

        }
        .foregroundStyle(ForecastPalette.ink)
        .padding(20)
        .glassCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("current-conditions-card")
    }
}

private struct AlertBanner: View {
    let alert: WeatherAlert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.symbolName).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.event).font(.headline)
                Text(alert.headline ?? "Tap for official alert details")
                    .font(.caption).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
        }
        .foregroundStyle(foregroundColor)
        .padding()
        .background(alert.severityColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityAddTraits(.isButton)
    }

    private var foregroundColor: Color {
        let severity = alert.severity.lowercased()
        return severity == "minor" || severity == "unknown" ? .black : .white
    }
}

private struct AlertAvailabilityBanner: View {
    var body: some View {
        Label(
            "Weather alerts are temporarily unavailable. Refresh before relying on this screen for hazards.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("Warning: National Weather Service alerts are temporarily unavailable")
    }
}

private struct HourlyStrip: View {
    let title: String
    let periods: [ForecastPeriod]
    let precipitationAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation
    @Binding var selectedTime: Date?
    @State private var centeredPeriodID: ForecastPeriod.ID?
    @State private var hasUserScrolledHorizontally = false
    var showsHeader = true
    var usesCardBackground = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                Label(title, systemImage: "clock")
                    .font(.headline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(periods) { period in
                        let precipitationVolume = precipitationVolume(during: period)

                        VStack(spacing: 7) {
                            Text(period.startTime, format: .dateTime.hour())
                                .font(.caption)
                            Image(systemName: period.symbolName)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    period.weatherTint,
                                    period.weatherSecondaryTint,
                                    period.weatherTertiaryTint
                                )
                                .font(.system(size: 32))
                                .frame(height: 38)
                            Text("\(period.temperature(in: unit))°")
                                .font(.headline)
                            if period.precipitationChance > 0 || (precipitationVolume ?? 0) > 0 {
                                Label(
                                    "\(formattedVolume(precipitationVolume)) (\(period.precipitationChance)%)",
                                    systemImage: "drop.fill"
                                )
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(ForecastPalette.blue)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                            } else {
                                Text(" ").font(.caption2)
                            }
                        }
                        .frame(width: 72)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityDescription(
                            for: period,
                            precipitationVolume: precipitationVolume
                        ))
                    }
                }
                .scrollTargetLayout()
            }
            .accessibilityIdentifier("hourly-forecast-strip")
            .accessibilityValue(centeredPeriodAccessibilityValue)
            .scrollPosition(id: $centeredPeriodID, anchor: .center)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else {
                            return
                        }
                        hasUserScrolledHorizontally = true
                    }
            )
            .onChange(of: centeredPeriodID) { _, periodID in
                guard hasUserScrolledHorizontally,
                      let periodID,
                      let period = periods.first(where: { $0.id == periodID }),
                      selectedTime != period.startTime else { return }
                selectedTime = period.startTime
            }
            .onChange(of: selectedTime) { _, time in
                guard let time,
                      let period = periods.first(where: { $0.startTime == time }),
                      centeredPeriodID != period.id else { return }
                withAnimation(.smooth(duration: 0.18)) {
                    centeredPeriodID = period.id
                }
            }
        }
        .foregroundStyle(ForecastPalette.ink)
        .padding()
        .modifier(OptionalGlassCard(enabled: usesCardBackground))
    }

    private func precipitationVolume(during period: ForecastPeriod) -> Double? {
        precipitationAmounts.precipitationVolume(during: period)
    }

    private var centeredPeriodAccessibilityValue: String {
        guard let centeredPeriodID,
              let period = periods.first(where: { $0.id == centeredPeriodID }) else {
            return "No centered hour"
        }
        return "Centered hour \(period.startTime.formatted(date: .omitted, time: .shortened))"
    }

    private func formattedVolume(_ millimeters: Double?) -> String {
        compactPrecipitationVolume(millimeters, unit: unit)
    }

    private func accessibleVolume(_ millimeters: Double?, during period: ForecastPeriod) -> String {
        guard let millimeters else { return "unavailable" }
        return PrecipitationAmount(
            startTime: period.startTime,
            endTime: period.endTime,
            millimeters: millimeters
        ).formattedAmount(for: unit)
    }

    private func accessibilityDescription(
        for period: ForecastPeriod,
        precipitationVolume: Double?
    ) -> String {
        let time = period.startTime.formatted(date: .omitted, time: .shortened)
        let amount = accessibleVolume(precipitationVolume, during: period)
        return "\(time), \(period.shortForecast), \(period.temperature(in: unit)) degrees, "
            + "\(period.precipitationChance) percent precipitation chance, "
            + "\(precipitationVolumeRepresentation.chartTitle.lowercased()) \(amount)"
    }
}

private struct OptionalGlassCard: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.glassCard()
        } else {
            content
        }
    }
}

private struct HourlyForecastCard: View {
    let periods: [ForecastPeriod]
    let precipitationAmounts: [PrecipitationAmount]
    let rawPrecipitationAmounts: [PrecipitationAmount]
    let expectedPrecipitationAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let forecastModel: ForecastModel
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation
    @State private var isExpanded = false
    @State private var expandedContentHeight: CGFloat = 0
    @State private var selectedTime: Date?

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.38)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("Next 24 hours", systemImage: "clock")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ForecastPalette.secondary.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .padding(.horizontal)
                .padding(.top)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next 24 hours")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses the 24-hour forecast" : "Expands the 24-hour forecast")

            HourlyStrip(
                title: "",
                periods: periods,
                precipitationAmounts: precipitationAmounts,
                unit: unit,
                precipitationVolumeRepresentation: precipitationVolumeRepresentation,
                selectedTime: $selectedTime,
                showsHeader: false,
                usesCardBackground: false
            )

            VStack(spacing: 0) {
                Divider()
                    .overlay(ForecastPalette.grid)
                    .padding(.horizontal)

                MeteogramCard(
                    periods: periods,
                    precipitationAmounts: precipitationAmounts,
                    rawPrecipitationAmounts: rawPrecipitationAmounts,
                    expectedPrecipitationAmounts: expectedPrecipitationAmounts,
                    unit: unit,
                    forecastModel: forecastModel,
                    precipitationVolumeRepresentation: precipitationVolumeRepresentation,
                    selectedTime: $selectedTime,
                    usesCardBackground: false,
                    isVisible: isExpanded
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard height > 0, abs(height - expandedContentHeight) > 0.5 else { return }
                expandedContentHeight = height
            }
            .opacity(isExpanded ? 1 : 0)
            .frame(height: isExpanded ? expandedContentHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .foregroundStyle(ForecastPalette.ink)
        .glassCard()
    }
}

private struct MeteogramCard: View {
    let title: String
    let periods: [ForecastPeriod]
    let precipitationAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let forecastModel: ForecastModel
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation
    let usesCardBackground: Bool
    let isVisible: Bool
    private let derivedData: MeteogramDerivedData
    @Binding private var selectedTime: Date?

    init(
        title: String = "24-hour forecast",
        periods: [ForecastPeriod],
        precipitationAmounts: [PrecipitationAmount],
        rawPrecipitationAmounts: [PrecipitationAmount],
        expectedPrecipitationAmounts: [PrecipitationAmount],
        unit: TemperatureUnit,
        forecastModel: ForecastModel,
        precipitationVolumeRepresentation: PrecipitationVolumeRepresentation,
        selectedTime: Binding<Date?>,
        usesCardBackground: Bool = true,
        isVisible: Bool = true
    ) {
        self.title = title
        self.periods = periods
        self.precipitationAmounts = precipitationAmounts
        self.unit = unit
        self.forecastModel = forecastModel
        self.precipitationVolumeRepresentation = precipitationVolumeRepresentation
        self._selectedTime = selectedTime
        self.usesCardBackground = usesCardBackground
        self.isVisible = isVisible
        derivedData = MeteogramDerivedData(
            periods: periods,
            rawPrecipitationAmounts: rawPrecipitationAmounts,
            expectedPrecipitationAmounts: expectedPrecipitationAmounts,
            unit: unit
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Capsule()
                        .fill(temperatureGradient)
                        .frame(width: 18, height: 3)
                    Text("Temperature \(unit.symbol)")
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(ForecastPalette.precipitation.opacity(0.72))
                        .frame(width: 9, height: 12)
                    Text("Volume")
                        .accessibilityIdentifier("precipitation-chart-legend")
                }
                HStack(spacing: 5) {
                    Capsule()
                        .fill(expectedPrecipitationGradient)
                        .frame(width: 18, height: 3)
                    Text("Expected")
                }
                Spacer(minLength: 0)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ForecastPalette.secondary)

            Chart {
                if let selectedPeriod {
                    RuleMark(
                        x: .value("Selected time", selectedPeriod.startTime)
                    )
                    .foregroundStyle(ForecastPalette.ink.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))
                    .annotation(
                        position: .top,
                        alignment: selectionAnnotationAlignment,
                        spacing: -26,
                        overflowResolution: AnnotationOverflowResolution(
                            x: .fit(to: .chart),
                            y: .disabled
                        )
                    ) {
                        selectionBadge(for: selectedPeriod)
                    }
                }

                ForEach(periods) { period in
                    if let amount = rawPrecipitationAmount(for: period), amount.millimeters > 0 {
                        BarMark(
                            x: .value("Hour", period.startTime),
                            yStart: .value("No precipitation", temperatureDomain.lowerBound),
                            yEnd: .value(
                                "Precipitation volume",
                                scaledAmount(amount.millimeters)
                            ),
                            width: .fixed(8)
                        )
                        .foregroundStyle(precipitationBarColor)
                        .cornerRadius(4)
                        .accessibilityLabel(
                            "Precipitation volume at \(period.startTime.formatted(date: .omitted, time: .shortened))"
                        )
                        .accessibilityValue(formattedRawPrecipitation(for: period))
                        .accessibilityIdentifier("precipitation-mark-\(period.id)")
                    }
                }

                ForEach(periods) { period in
                    if let amount = expectedPrecipitationAmount(for: period) {
                        LineMark(
                            x: .value("Expected precipitation time", period.startTime),
                            y: .value(
                                "Expected precipitation glow",
                                scaledAmount(amount.millimeters)
                            ),
                            series: .value("Series", "Expected precipitation glow")
                        )
                        .foregroundStyle(ForecastPalette.expectedPrecipitationGlow)
                        .lineStyle(StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                    }
                }

                ForEach(periods) { period in
                    if let amount = expectedPrecipitationAmount(for: period) {
                        LineMark(
                            x: .value("Expected precipitation time", period.startTime),
                            y: .value(
                                "Expected precipitation",
                                scaledAmount(amount.millimeters)
                            ),
                            series: .value("Series", "Expected precipitation")
                        )
                        .foregroundStyle(expectedPrecipitationGradient)
                        .lineStyle(StrokeStyle(lineWidth: 2.75, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                        .accessibilityLabel(
                            "Expected precipitation at \(period.startTime.formatted(date: .omitted, time: .shortened))"
                        )
                        .accessibilityValue(formattedExpectedPrecipitation(for: period))
                        .accessibilityIdentifier("expected-precipitation-mark-\(period.id)")

                        if selectedPeriod?.id == period.id {
                            PointMark(
                                x: .value("Selected expected precipitation time", period.startTime),
                                y: .value(
                                    "Selected expected precipitation",
                                    scaledAmount(amount.millimeters)
                                )
                            )
                            .foregroundStyle(ForecastPalette.card)
                            .symbolSize(88)

                            PointMark(
                                x: .value("Selected expected precipitation time", period.startTime),
                                y: .value(
                                    "Selected expected precipitation",
                                    scaledAmount(amount.millimeters)
                                )
                            )
                            .foregroundStyle(ForecastPalette.expectedPrecipitation)
                            .symbolSize(38)
                        }
                    }
                }

                ForEach(periods) { period in
                    LineMark(
                        x: .value("Time", period.startTime),
                        y: .value("Temperature glow", Double(period.temperature(in: unit))),
                        series: .value("Series", "Temperature glow")
                    )
                    .foregroundStyle(ForecastPalette.temperatureGlow)
                    .lineStyle(StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }

                ForEach(periods) { period in
                    LineMark(
                        x: .value("Time", period.startTime),
                        y: .value("Temperature", Double(period.temperature(in: unit))),
                        series: .value("Series", "Temperature")
                    )
                    .foregroundStyle(temperatureGradient)
                    .lineStyle(StrokeStyle(lineWidth: 2.75, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                    .accessibilityLabel(
                        "Temperature at \(period.startTime.formatted(date: .omitted, time: .shortened))"
                    )
                    .accessibilityValue("\(period.temperature(in: unit))\(unit.symbol)")
                    .accessibilityIdentifier("temperature-mark-\(period.id)")

                    if selectedPeriod?.id == period.id {
                        PointMark(
                            x: .value("Selected time", period.startTime),
                            y: .value("Selected temperature", Double(period.temperature(in: unit)))
                        )
                        .foregroundStyle(ForecastPalette.card)
                        .symbolSize(88)

                        PointMark(
                            x: .value("Selected time", period.startTime),
                            y: .value("Selected temperature", Double(period.temperature(in: unit)))
                        )
                        .foregroundStyle(ForecastPalette.temperatureEnd)
                        .symbolSize(38)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(ForecastPalette.grid)
                    AxisValueLabel {
                        if let temperature = value.as(Double.self) {
                            Text("\(Int(temperature.rounded()))°")
                        }
                    }
                    .foregroundStyle(ForecastPalette.secondary)
                }
                AxisMarks(position: .trailing, values: precipitationAxisValues) { value in
                    AxisTick().foregroundStyle(ForecastPalette.blue.opacity(0.5))
                    AxisValueLabel {
                        if let scaledValue = value.as(Double.self) {
                            Text(precipitationAxisLabel(for: scaledValue))
                        }
                    }
                    .foregroundStyle(ForecastPalette.blue)
                }
            }
            .chartYScale(domain: temperatureDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisGridLine().foregroundStyle(ForecastPalette.grid.opacity(0.7))
                    AxisValueLabel(
                        format: .dateTime.hour(),
                        centered: false,
                        anchor: .top,
                        collisionResolution: .disabled,
                        offsetsMarks: false
                    )
                        .foregroundStyle(ForecastPalette.secondary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    MeteogramInteractionOverlay(
                        onTap: { location in
                            selectTime(
                                at: location,
                                proxy: proxy,
                                geometry: geometry
                            )
                        },
                        onHorizontalDragChanged: { location in
                            selectTime(
                                at: location,
                                proxy: proxy,
                                geometry: geometry
                            )
                        },
                        onHorizontalDragEnded: { location in
                            selectTime(
                                at: location,
                                proxy: proxy,
                                geometry: geometry
                            )
                        }
                    )
                }
            }
            .frame(height: 220)
            .onChange(of: periods.map(\.startTime)) { _, _ in
                selectedTime = nil
            }
            .onChange(of: isVisible) { _, visible in
                if !visible { selectedTime = nil }
            }
            .accessibilityLabel(
                "Combined 24 hour temperature and precipitation chart. "
                    + "Blue bars show precipitation volume. "
                    + "The cyan line shows probability-weighted expected precipitation."
            )
            .accessibilityValue(selectedPeriodAccessibilityValue)
            .accessibilityHint("Swipe horizontally to move the time indicator")
            .accessibilityAdjustableAction { direction in
                moveSelection(direction)
            }
            .accessibilityIdentifier("temperature-precipitation-chart")

            Divider().overlay(ForecastPalette.grid)

            PrecipitationDetail(
                periods: periods,
                amounts: relevantPrecipitationAmounts,
                unit: unit,
                precipitationVolumeRepresentation: precipitationVolumeRepresentation
            )
        }
        .foregroundStyle(ForecastPalette.ink)
        .padding()
        .modifier(OptionalGlassCard(enabled: usesCardBackground))
        .task(id: selectedTime) {
            await dismissSelectionAfterDelay()
        }
    }

    private var temperatureDomain: ClosedRange<Double> {
        derivedData.temperatureDomain
    }

    private var precipitationBarColor: Color {
        ForecastPalette.precipitation.opacity(0.7)
    }

    private var temperatureGradient: LinearGradient {
        LinearGradient(
            colors: [ForecastPalette.temperatureStart, ForecastPalette.temperatureEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var expectedPrecipitationGradient: LinearGradient {
        LinearGradient(
            colors: [
                ForecastPalette.expectedPrecipitationStart,
                ForecastPalette.expectedPrecipitation
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var selectedPeriod: ForecastPeriod? {
        guard let selectedTime else { return nil }
        return derivedData.periodByStartTime[selectedTime]
    }

    private var selectionAnnotationAlignment: Alignment {
        guard let selectedPeriod,
              let index = periods.firstIndex(where: { $0.id == selectedPeriod.id }) else {
            return .center
        }
        if index < periods.count / 3 { return .leading }
        if index >= periods.count * 2 / 3 { return .trailing }
        return .center
    }

    private var selectedPeriodAccessibilityValue: String {
        guard let period = selectedPeriod else { return "No time selected" }
        return "Selected \(period.startTime.formatted(date: .omitted, time: .shortened)), "
            + "temperature \(period.temperature(in: unit))\(unit.symbol), "
            + "precipitation volume \(formattedRawPrecipitation(for: period)), "
            + "expected precipitation \(formattedExpectedPrecipitation(for: period)), "
            + "\(period.precipitationChance) percent chance"
    }

    private var precipitationAxisValues: [Double] {
        return [0, precipitationAmountUpperBound / 2, precipitationAmountUpperBound]
            .map(scaledDisplayedAmount)
    }

    private func precipitationAxisLabel(for scaledValue: Double) -> String {
        let amount = displayedAmount(for: scaledValue)
        if unit == .celsius {
            return amount < 10
                ? String(format: "%.1f mm", amount)
                : String(format: "%.0f mm", amount)
        }
        return String(format: "%.2f in", amount)
    }

    private var precipitationAmountUpperBound: Double {
        derivedData.precipitationAmountUpperBound
    }

    private func scaledAmount(_ millimeters: Double) -> Double {
        scaledDisplayedAmount(displayAmount(millimeters))
    }

    private func scaledDisplayedAmount(_ amount: Double) -> Double {
        let span = temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard precipitationAmountUpperBound > 0 else { return temperatureDomain.lowerBound }
        return temperatureDomain.lowerBound
            + min(max(amount / precipitationAmountUpperBound, 0), 1) * span
    }

    private func displayedAmount(for scaledValue: Double) -> Double {
        let span = temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard span > 0 else { return 0 }
        return max(0, (scaledValue - temperatureDomain.lowerBound) / span)
            * precipitationAmountUpperBound
    }

    private func displayAmount(_ millimeters: Double) -> Double {
        unit == .celsius ? millimeters : millimeters / 25.4
    }

    private func rawPrecipitationAmount(for period: ForecastPeriod) -> PrecipitationAmount? {
        derivedData.rawPrecipitationByPeriodID[period.id]
    }

    private func expectedPrecipitationAmount(for period: ForecastPeriod) -> PrecipitationAmount? {
        derivedData.expectedPrecipitationByPeriodID[period.id]
    }

    private func formattedRawPrecipitation(for period: ForecastPeriod) -> String {
        formattedPrecipitation(rawPrecipitationAmount(for: period)?.millimeters)
    }

    private func formattedExpectedPrecipitation(for period: ForecastPeriod) -> String {
        formattedPrecipitation(expectedPrecipitationAmount(for: period)?.millimeters)
    }

    private func formattedPrecipitation(_ millimeters: Double?) -> String {
        guard let millimeters else {
            return unit == .celsius ? "0 mm" : "0 in"
        }
        if unit == .celsius {
            if millimeters > 0, millimeters < 0.1 { return "<0.1 mm" }
            if millimeters < 10 { return String(format: "%.1f mm", millimeters) }
            return String(format: "%.0f mm", millimeters)
        }

        let inches = millimeters / 25.4
        if inches > 0, inches < 0.01 { return "<0.01 in" }
        if inches < 1 { return String(format: "%.2f in", inches) }
        return String(format: "%.1f in", inches)
    }

    private func selectionBadge(for period: ForecastPeriod) -> some View {
        HStack(spacing: 6) {
            Text(period.startTime, format: .dateTime.hour().minute())
                .fontWeight(.bold)
            Text("\(period.temperature(in: unit))\(unit.symbol)")
            Label(formattedRawPrecipitation(for: period), systemImage: "drop.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.white)
            Label(formattedExpectedPrecipitation(for: period), systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(ForecastPalette.expectedPrecipitation)
        }
            .font(.caption2.monospacedDigit())
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ForecastPalette.badgeBackground, in: Capsule())
            .accessibilityIdentifier("meteogram-time-indicator")
    }

    private func moveSelection(_ direction: AccessibilityAdjustmentDirection) {
        guard !periods.isEmpty else { return }
        let currentIndex = selectedPeriod.flatMap { selected in
            periods.firstIndex(where: { $0.id == selected.id })
        }
        let nextIndex: Int
        switch direction {
        case .increment:
            nextIndex = min((currentIndex ?? -1) + 1, periods.count - 1)
        case .decrement:
            nextIndex = max((currentIndex ?? periods.count) - 1, 0)
        @unknown default:
            return
        }
        selectedTime = periods[nextIndex].startTime
    }

    private func dismissSelectionAfterDelay() async {
        guard selectedTime != nil else { return }
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            selectedTime = nil
        }
    }

    private func selectTime(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard location.y >= frame.minY, location.y <= frame.maxY else { return }
        let plotX = min(max(location.x - frame.minX, 0), frame.width)
        guard let date = proxy.value(atX: plotX, as: Date.self),
              let period = periods.min(by: {
                  abs($0.startTime.timeIntervalSince(date))
                      < abs($1.startTime.timeIntervalSince(date))
              }) else { return }
        if selectedTime != period.startTime {
            selectedTime = period.startTime
        }
    }

    private var relevantPrecipitationAmounts: [PrecipitationAmount] {
        guard let first = periods.first, let last = periods.last else { return [] }
        return precipitationAmounts
            .filter { $0.endTime > first.startTime && $0.startTime < last.endTime }
            .sorted { $0.startTime < $1.startTime }
    }
}

private struct MeteogramDerivedData {
    let temperatureDomain: ClosedRange<Double>
    let rawPrecipitationByPeriodID: [Int: PrecipitationAmount]
    let expectedPrecipitationByPeriodID: [Int: PrecipitationAmount]
    let periodByStartTime: [Date: ForecastPeriod]
    let precipitationAmountUpperBound: Double

    init(
        periods: [ForecastPeriod],
        rawPrecipitationAmounts: [PrecipitationAmount],
        expectedPrecipitationAmounts: [PrecipitationAmount],
        unit: TemperatureUnit
    ) {
        let temperatures = periods.map { Double($0.temperature(in: unit)) }
        if let minimum = temperatures.min(), let maximum = temperatures.max() {
            let padding = max(4, (maximum - minimum) * 0.2)
            temperatureDomain = (minimum - padding)...(maximum + padding)
        } else {
            temperatureDomain = 0...100
        }

        let rawByPeriodID = Self.amountsByPeriodID(
            periods: periods,
            precipitationAmounts: rawPrecipitationAmounts
        )
        let expectedByPeriodID = Self.amountsByPeriodID(
            periods: periods,
            precipitationAmounts: expectedPrecipitationAmounts
        )
        rawPrecipitationByPeriodID = rawByPeriodID
        expectedPrecipitationByPeriodID = expectedByPeriodID
        periodByStartTime = Dictionary(
            periods.map { ($0.startTime, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let maximum = periods.compactMap { period -> Double? in
            guard let amount = rawByPeriodID[period.id]
                ?? expectedByPeriodID[period.id] else { return nil }
            return unit == .celsius ? amount.millimeters : amount.millimeters / 25.4
        }.max() ?? 0
        let minimum = unit == .celsius ? 1.0 : 0.05
        let padded = max(minimum, maximum * 1.12)
        let step: Double
        if unit == .celsius {
            step = padded <= 5 ? 1 : (padded <= 20 ? 5 : 10)
        } else {
            step = padded <= 0.25 ? 0.05 : (padded <= 1 ? 0.25 : 0.5)
        }
        precipitationAmountUpperBound = (padded / step).rounded(.up) * step
    }

    private static func amountsByPeriodID(
        periods: [ForecastPeriod],
        precipitationAmounts: [PrecipitationAmount]
    ) -> [Int: PrecipitationAmount] {
        var result: [Int: PrecipitationAmount] = [:]
        for period in periods {
            guard let millimeters = precipitationAmounts.precipitationVolume(during: period) else {
                continue
            }
            result[period.id] = PrecipitationAmount(
                startTime: period.startTime,
                endTime: period.endTime,
                millimeters: millimeters
            )
        }
        return result
    }
}

private struct MeteogramInteractionOverlay: UIViewRepresentable {
    let onTap: (CGPoint) -> Void
    let onHorizontalDragChanged: (CGPoint) -> Void
    let onHorizontalDragEnded: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MeteogramInteractionOverlay

        init(parent: MeteogramInteractionOverlay) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onTap(recognizer.location(in: view))
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began, .changed:
                parent.onHorizontalDragChanged(location)
            case .ended, .cancelled:
                parent.onHorizontalDragEnded(location)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else {
                return true
            }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct PrecipitationDetail: View {
    @Environment(\.timeZone) private var timeZone
    let periods: [ForecastPeriod]
    let amounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Precipitation detail", systemImage: "drop.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(
                    precipitationVolumeRepresentation == .expected
                        ? "Probability-weighted totals"
                        : "Raw model totals"
                )
                    .font(.caption2)
                    .foregroundStyle(ForecastPalette.secondary)
            }

            if amounts.isEmpty {
                Label("Accumulation forecast temporarily unavailable", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(ForecastPalette.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(amounts) { amount in
                            amountCard(amount)
                        }
                    }
                }
            }
        }
    }

    private func amountCard(_ amount: PrecipitationAmount) -> some View {
        let chance = peakChance(during: amount)
        let durationHours = max(1, Int((amount.endTime.timeIntervalSince(amount.startTime) / 3_600).rounded()))

        return VStack(alignment: .leading, spacing: 7) {
            Text(timeRange(for: amount))
                .font(.caption.weight(.semibold))
                .foregroundStyle(ForecastPalette.ink)
            HStack(spacing: 5) {
                Text("Chance").foregroundStyle(ForecastPalette.secondary)
                Spacer(minLength: 2)
                Text("\(chance)% peak").foregroundStyle(ForecastPalette.blue)
            }
            HStack(spacing: 5) {
                Text("Amount").foregroundStyle(ForecastPalette.secondary)
                Spacer(minLength: 2)
                Text(amount.formattedAmount(for: unit)).foregroundStyle(ForecastPalette.ink)
            }
            Text("\(durationHours)-hour total")
                .font(.caption2)
                .foregroundStyle(ForecastPalette.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .frame(width: 142, alignment: .leading)
        .background(ForecastPalette.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(ForecastPalette.blue.opacity(0.16))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(timeRange(for: amount)), \(chance) percent peak precipitation chance, "
                + "\(amount.formattedAmount(for: unit)), \(durationHours) hour total"
        )
    }

    private func peakChance(during amount: PrecipitationAmount) -> Int {
        periods
            .filter { $0.endTime > amount.startTime && $0.startTime < amount.endTime }
            .map(\.precipitationChance)
            .max() ?? 0
    }

    private func timeRange(for amount: PrecipitationAmount) -> String {
        let start = formattedHour(amount.startTime)
        let end = formattedHour(amount.endTime)
        return "\(start)–\(end)"
    }

    private func formattedHour(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = timeZone
        return date.formatted(style)
    }
}

private struct DailyForecastCard: View {
    let periods: [ForecastPeriod]
    let hourlyPeriods: [ForecastPeriod]
    let hourlyPrecipitationAmounts: [PrecipitationAmount]
    let rawHourlyPrecipitationAmounts: [PrecipitationAmount]
    let expectedHourlyPrecipitationAmounts: [PrecipitationAmount]
    let dailyPrecipitationAmounts: [PrecipitationAmount]
    let rawDailyPrecipitationAmounts: [PrecipitationAmount]
    let expectedDailyPrecipitationAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let altitudeUnit: AltitudeUnit
    let location: WeatherLocation
    let forecastModel: ForecastModel
    let hourlyForecastModel: ForecastModel
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation
    let selectedForecastModel: ForecastModel
    let isLoading: Bool
    let onSelectForecastModel: (ForecastModel) -> Void
    @State private var showsForecastInfo = false
    @State private var displayMode: DailyForecastDisplayMode = .summary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(forecastHeading, systemImage: "calendar")
                    .font(.headline)
                    .accessibilityIdentifier("daily-forecast-heading-\(forecastModel.rawValue)")
                Spacer()
                if isLoading, selectedForecastModel != forecastModel {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading \(selectedForecastModel.shortName) daily forecast")
                }

                Button {
                    showsForecastInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ForecastPalette.blue)
                .accessibilityLabel("About forecast models and histogram")
                .popover(isPresented: $showsForecastInfo) {
                    DailyForecastInfo(
                        location: location,
                        altitudeUnit: altitudeUnit,
                        dailyModel: forecastModel,
                        hourlyModel: hourlyForecastModel
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
            .padding(.bottom, 10)

            Picker(
                "Daily forecast model",
                selection: Binding(
                    get: { selectedForecastModel },
                    set: onSelectForecastModel
                )
            ) {
                ForEach(ForecastModel.allCases) { model in
                    Text(model.shortName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 8)

            Picker("Daily forecast view", selection: $displayMode) {
                ForEach(DailyForecastDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("daily-forecast-display-mode")
            .padding(.bottom, 12)

            ForEach(Array(dailyRows.enumerated()), id: \.element.id) { index, row in
                NavigationLink {
                    DayForecastDetailView(
                        row: row,
                        hourlyPeriods: hourlyPeriods.filter {
                            $0.endTime > row.startTime && $0.startTime < row.endTime
                        },
                        precipitationAmounts: hourlyPrecipitationAmounts.filter {
                            $0.endTime > row.startTime && $0.startTime < row.endTime
                        },
                        dailyPrecipitationAmounts: dailyPrecipitationAmounts,
                        rawHourlyPrecipitationAmounts: rawHourlyPrecipitationAmounts,
                        expectedHourlyPrecipitationAmounts: expectedHourlyPrecipitationAmounts,
                        rawDailyPrecipitationAmounts: rawDailyPrecipitationAmounts,
                        expectedDailyPrecipitationAmounts: expectedDailyPrecipitationAmounts,
                        unit: unit,
                        forecastModel: forecastModel,
                        precipitationVolumeRepresentation: precipitationVolumeRepresentation
                    )
                } label: {
                    DailyForecastSummary(
                        row: row,
                        hourlyPeriods: hourlyPeriods.filter {
                            $0.endTime > row.startTime && $0.startTime < row.endTime
                        },
                        rawHourlyPrecipitationAmounts: rawHourlyPrecipitationAmounts,
                        expectedHourlyPrecipitationAmounts: expectedHourlyPrecipitationAmounts,
                        rawDailyPrecipitationAmounts: rawDailyPrecipitationAmounts,
                        expectedDailyPrecipitationAmounts: expectedDailyPrecipitationAmounts,
                        precipitationAmounts: dailyPrecipitationAmounts,
                        unit: unit,
                        timeZone: location.timeZone,
                        displayMode: displayMode,
                        precipitationVolumeRepresentation: precipitationVolumeRepresentation
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("daily-forecast-\(row.id)")
                .accessibilityHint("Opens the detailed forecast for \(row.name)")
                .padding(.vertical, 8)

                if index < dailyRows.count - 1 {
                    Divider().overlay(ForecastPalette.grid)
                }
            }
        }
        .foregroundStyle(ForecastPalette.ink)
        .padding()
        .glassCard()
    }

    private var dailyRows: [DailyForecastRow] {
        var rows: [DailyForecastRow] = []
        var index = periods.startIndex

        while index < periods.endIndex {
            let period = periods[index]
            if period.isDaytime {
                let nextIndex = periods.index(after: index)
                let nighttime = nextIndex < periods.endIndex && !periods[nextIndex].isDaytime
                    ? periods[nextIndex]
                    : nil
                rows.append(DailyForecastRow(daytime: period, nighttime: nighttime))
                index = nighttime == nil ? nextIndex : periods.index(after: nextIndex)
            } else {
                rows.append(DailyForecastRow(daytime: nil, nighttime: period))
                index = periods.index(after: index)
            }
        }

        return rows
    }

    private var forecastHeading: String {
        "\(dailyRows.count)-day forecast"
    }
}

private enum DailyForecastDisplayMode: String, CaseIterable, Identifiable {
    case summary
    case histogram

    var id: Self { self }

    var title: String {
        switch self {
        case .summary: return "Summary"
        case .histogram: return "Histogram"
        }
    }
}

private struct DailyForecastInfo: View {
    let location: WeatherLocation
    let altitudeUnit: AltitudeUnit
    let dailyModel: ForecastModel
    let hourlyModel: ForecastModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About this forecast")
                .font(.headline)

            if let elevation = summitElevation {
                Label(
                    "HRRR is provider-downscaled to \(elevation).",
                    systemImage: "mountain.2.fill"
                )
                Label(
                    "NWS temperatures are adjusted to \(elevation). Wind, precipitation, and weather type remain NWS grid guidance.",
                    systemImage: "square.grid.3x3.fill"
                )
            }

            Label(
                "Percentages are precipitation chance—not rainfall amount.",
                systemImage: "drop.fill"
            )

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text("Histogram key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForecastPalette.secondary)

                histogramKey(title: "Precipitation volume") {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(ForecastPalette.precipitation.opacity(0.72))
                        .frame(width: 10, height: 14)
                }
                histogramKey(title: "Expected precipitation") {
                    Capsule()
                        .fill(expectedPrecipitationGradient)
                        .frame(width: 22, height: 3)
                }
            }

            Label(sourceContext, systemImage: "clock.fill")
        }
        .font(.subheadline)
        .foregroundStyle(ForecastPalette.ink)
        .frame(idealWidth: 340, maxWidth: 380, alignment: .leading)
        .padding()
        .accessibilityIdentifier("daily-forecast-info")
    }

    private var summitElevation: String? {
        guard location.kind == .summit,
              let elevation = location.elevation?.formatted(for: altitudeUnit) else { return nil }
        return elevation
    }

    private var sourceContext: String {
        if dailyModel == hourlyModel {
            return "Tap a day for \(dailyModel.shortName) timing, wind, and expected amount."
        }
        return "Daily outlook: \(dailyModel.shortName) · Hourly timing and amounts: \(hourlyModel.shortName)."
    }

    private func histogramKey<Swatch: View>(
        title: String,
        @ViewBuilder swatch: () -> Swatch
    ) -> some View {
        HStack(spacing: 8) {
            swatch().frame(width: 24, alignment: .center)
            Text(title)
        }
    }

    private var expectedPrecipitationGradient: LinearGradient {
        LinearGradient(
            colors: [
                ForecastPalette.expectedPrecipitationStart,
                ForecastPalette.expectedPrecipitation
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct DailyForecastRow: Identifiable {
    let daytime: ForecastPeriod?
    let nighttime: ForecastPeriod?

    var id: Int { daytime?.id ?? nighttime?.id ?? 0 }

    var startTime: Date {
        daytime?.startTime ?? nighttime?.startTime ?? .distantPast
    }

    var endTime: Date {
        nighttime?.endTime ?? daytime?.endTime ?? .distantFuture
    }

    func calendarDayStart(in timeZone: TimeZone) -> Date {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: startTime)
    }

    func calendarDayEnd(in timeZone: TimeZone) -> Date {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let start = calendarDayStart(in: timeZone)
        return calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
    }

    var name: String {
        if let daytime { return daytime.name }
        guard let nighttime else { return "Forecast" }
        switch nighttime.name.lowercased() {
        case "tonight", "overnight": return "Today"
        default:
            return nighttime.name.lowercased().hasSuffix(" night")
                ? String(nighttime.name.dropLast(" Night".count))
                : nighttime.name
        }
    }

}

private struct DayForecastDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    let row: DailyForecastRow
    let hourlyPeriods: [ForecastPeriod]
    let precipitationAmounts: [PrecipitationAmount]
    let dailyPrecipitationAmounts: [PrecipitationAmount]
    let rawHourlyPrecipitationAmounts: [PrecipitationAmount]
    let expectedHourlyPrecipitationAmounts: [PrecipitationAmount]
    let rawDailyPrecipitationAmounts: [PrecipitationAmount]
    let expectedDailyPrecipitationAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let forecastModel: ForecastModel
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation
    @State private var selectedTime: Date?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.025, green: 0.075, blue: 0.11), Color(red: 0.055, green: 0.15, blue: 0.21)]
                    : [Color(red: 0.94, green: 0.98, blue: 1), Color(red: 0.78, green: 0.9, blue: 0.97)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detailed forecast")
                            .font(.title2.bold())
                        Text(
                            row.startTime,
                            format: .dateTime.weekday(.wide).month(.wide).day()
                        )
                            .font(.subheadline)
                            .foregroundStyle(ForecastPalette.secondary)
                    }

                    if let daytime = row.daytime {
                        DetailedPeriodCard(label: "Day", period: daytime, unit: unit)
                    }
                    if let nighttime = row.nighttime {
                        DetailedPeriodCard(label: "Night", period: nighttime, unit: unit)
                    }

                    if !hourlyPeriods.isEmpty {
                        VStack(spacing: 0) {
                            HourlyStrip(
                                title: "Hourly forecast",
                                periods: hourlyPeriods,
                                precipitationAmounts: precipitationAmounts,
                                unit: unit,
                                precipitationVolumeRepresentation: precipitationVolumeRepresentation,
                                selectedTime: $selectedTime,
                                usesCardBackground: false
                            )

                            if !chartPeriods.isEmpty {
                                Divider()
                                    .overlay(ForecastPalette.grid)
                                    .padding(.horizontal)

                                MeteogramCard(
                                    title: "Hourly timeline",
                                    periods: chartPeriods,
                                    precipitationAmounts: chartPrecipitationAmounts,
                                    rawPrecipitationAmounts: chartRawPrecipitationAmounts,
                                    expectedPrecipitationAmounts: chartExpectedPrecipitationAmounts,
                                    unit: unit,
                                    forecastModel: forecastModel,
                                    precipitationVolumeRepresentation: precipitationVolumeRepresentation,
                                    selectedTime: $selectedTime,
                                    usesCardBackground: false
                                )
                            }
                        }
                        .glassCard()
                    } else if !chartPeriods.isEmpty {
                        MeteogramCard(
                            title: "Hourly timeline",
                            periods: chartPeriods,
                            precipitationAmounts: chartPrecipitationAmounts,
                            rawPrecipitationAmounts: chartRawPrecipitationAmounts,
                            expectedPrecipitationAmounts: chartExpectedPrecipitationAmounts,
                            unit: unit,
                            forecastModel: forecastModel,
                            precipitationVolumeRepresentation: precipitationVolumeRepresentation,
                            selectedTime: $selectedTime
                        )
                    }

                    Text(forecastModel.forecastAttribution)
                        .font(.caption)
                        .foregroundStyle(ForecastPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
                .padding()
            }
        }
        .foregroundStyle(ForecastPalette.ink)
        .navigationTitle(row.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chartUsesHourlyData: Bool {
        !hourlyPeriods.isEmpty
    }

    private var chartPeriods: [ForecastPeriod] {
        if chartUsesHourlyData { return hourlyPeriods }
        return [row.daytime, row.nighttime].compactMap { $0 }
    }

    private var chartPrecipitationAmounts: [PrecipitationAmount] {
        chartUsesHourlyData ? precipitationAmounts : dailyPrecipitationAmounts
    }

    private var chartRawPrecipitationAmounts: [PrecipitationAmount] {
        chartUsesHourlyData
            ? rawHourlyPrecipitationAmounts
            : rawDailyPrecipitationAmounts
    }

    private var chartExpectedPrecipitationAmounts: [PrecipitationAmount] {
        chartUsesHourlyData
            ? expectedHourlyPrecipitationAmounts
            : expectedDailyPrecipitationAmounts
    }
}

private struct DetailedPeriodCard: View {
    let label: String
    let period: ForecastPeriod
    let unit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: period.symbolName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        period.weatherTint,
                        period.weatherSecondaryTint,
                        period.weatherTertiaryTint
                    )
                    .font(.system(size: 54))
                    .frame(width: 64, height: 60)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ForecastPalette.secondary)
                    Text(period.shortForecast)
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(period.temperature(in: unit))°")
                        .font(.title.bold().monospacedDigit())
                    Text(label == "Day" ? "High" : "Low")
                        .font(.caption)
                        .foregroundStyle(ForecastPalette.secondary)
                }
            }

            HStack(spacing: 16) {
                Label("\(period.precipitationChance)% chance", systemImage: "drop.fill")
                    .foregroundStyle(ForecastPalette.blue)
                Label(period.windSpeed, systemImage: "wind")
                    .foregroundStyle(ForecastPalette.secondary)
            }
            .font(.caption.weight(.medium))

            Divider().overlay(ForecastPalette.grid)

            Text(period.detailedForecast.isEmpty ? period.shortForecast : period.detailedForecast)
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .glassCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label), \(period.shortForecast), \(period.temperature(in: unit)) degrees, "
                + "\(period.precipitationChance) percent precipitation, wind \(period.windSpeed). "
                + (period.detailedForecast.isEmpty ? period.shortForecast : period.detailedForecast)
        )
    }
}

private struct DailyForecastSummary: View {
    let row: DailyForecastRow
    let hourlyPeriods: [ForecastPeriod]
    let rawHourlyPrecipitationAmounts: [PrecipitationAmount]
    let expectedHourlyPrecipitationAmounts: [PrecipitationAmount]
    let rawDailyPrecipitationAmounts: [PrecipitationAmount]
    let expectedDailyPrecipitationAmounts: [PrecipitationAmount]
    let precipitationAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let timeZone: TimeZone
    let displayMode: DailyForecastDisplayMode
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                DailyTemperaturePair(row: row, unit: unit)
            }

            Spacer(minLength: 4)

            switch displayMode {
            case .summary:
                DailyIconTransition(
                    row: row,
                    precipitationAmounts: precipitationAmounts,
                    unit: unit,
                    precipitationVolumeRepresentation: precipitationVolumeRepresentation
                )
            case .histogram:
                DailyPrecipitationHistogram(
                    periods: histogramPeriods,
                    rawAmounts: histogramUsesHourlyData
                        ? rawHourlyPrecipitationAmounts
                        : rawDailyPrecipitationAmounts,
                    expectedAmounts: histogramUsesHourlyData
                        ? expectedHourlyPrecipitationAmounts
                        : expectedDailyPrecipitationAmounts,
                    unit: unit,
                    timeZone: timeZone,
                    dayStart: row.calendarDayStart(in: timeZone),
                    dayEnd: row.calendarDayEnd(in: timeZone)
                )
            }
        }
        .contentShape(Rectangle())
    }

    private var histogramUsesHourlyData: Bool {
        !hourlyPeriods.isEmpty
    }

    private var histogramPeriods: [ForecastPeriod] {
        if histogramUsesHourlyData { return hourlyPeriods }
        return [row.daytime, row.nighttime].compactMap { $0 }
    }
}

private struct DailyPrecipitationHistogram: View {
    let periods: [ForecastPeriod]
    let rawAmounts: [PrecipitationAmount]
    let expectedAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let timeZone: TimeZone
    let dayStart: Date
    let dayEnd: Date

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                GeometryReader { proxy in
                    let expectedPath = smoothPath(
                        through: expectedPoints(
                            availableWidth: proxy.size.width,
                            availableHeight: proxy.size.height
                        )
                    )
                    ZStack(alignment: .bottom) {
                        VStack(spacing: 0) {
                            Rectangle().frame(height: 1)
                            Spacer()
                            Rectangle().frame(height: 1)
                            Spacer()
                            Rectangle().frame(height: 1)
                        }
                        .foregroundStyle(ForecastPalette.grid.opacity(0.65))

                        ForEach(dayPeriods) { period in
                            let width = barWidth(for: period, availableWidth: proxy.size.width)
                            let height = barHeight(for: period, availableHeight: proxy.size.height)

                            if rawVolume(for: period) > 0 {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(ForecastPalette.precipitation.opacity(0.72))
                                    .frame(width: max(2, width - 1), height: height)
                                    .position(
                                        x: periodCenterX(
                                            for: period,
                                            availableWidth: proxy.size.width
                                        ),
                                        y: proxy.size.height - (height / 2)
                                    )
                            }
                        }

                        expectedPath
                            .stroke(
                                ForecastPalette.expectedPrecipitationGlow,
                                style: StrokeStyle(
                                    lineWidth: 5,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        expectedPath
                            .stroke(
                                expectedPrecipitationGradient,
                                style: StrokeStyle(
                                    lineWidth: 2,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )

                    }
                    .background(ForecastPalette.grid.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(ForecastPalette.grid.opacity(0.8), lineWidth: 1)
                    }
                }
                .frame(height: 72)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(formattedScaleAmount(scaleMaximumMillimeters))
                    Spacer()
                    Text(formattedScaleAmount(scaleMaximumMillimeters / 2))
                    Spacer()
                    Text("0")
                }
                .font(.system(size: 8, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(ForecastPalette.secondary)
                .frame(width: 34, height: 72, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            HStack(spacing: 4) {
                if dayPeriods.isEmpty {
                    Text("Unavailable")
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    GeometryReader { proxy in
                        ForEach(axisDates, id: \.self) { date in
                            Text(formattedTime(date))
                                .position(
                                    x: axisX(for: date, availableWidth: proxy.size.width),
                                    y: proxy.size.height / 2
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Color.clear.frame(width: 34, height: 1)
            }
            .font(.system(size: 8, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(ForecastPalette.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: 10)
        }
        .frame(width: 152)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            dayPeriods.isEmpty
                ? "Daily weather histogram unavailable"
                : "24-hour precipitation histogram. Blue bars show precipitation volume and cyan line shows expected precipitation. Scale maximum \(formattedScaleAmount(scaleMaximumMillimeters))."
        )
        .accessibilityIdentifier("daily-precipitation-histogram")
    }

    private var scaleMaximumMillimeters: Double {
        let minimum = unit == .celsius ? 0.1 : 0.01 * 25.4
        let maximum = dayPeriods.flatMap { period in
            [rawVolume(for: period), expectedVolume(for: period)]
        }.max() ?? 0
        return maximum > 0 ? maximum * 1.1 : minimum
    }

    private func barHeight(
        for period: ForecastPeriod,
        availableHeight: CGFloat
    ) -> CGFloat {
        let millimeters = rawVolume(for: period)
        guard millimeters > 0 else { return 0 }
        return min(
            availableHeight,
            max(3, availableHeight * millimeters / scaleMaximumMillimeters)
        )
    }

    private var dayPeriods: [ForecastPeriod] {
        periods
            .filter { $0.endTime > dayStart && $0.startTime < dayEnd }
            .sorted { $0.startTime < $1.startTime }
    }

    private var dayDuration: TimeInterval {
        max(dayEnd.timeIntervalSince(dayStart), 1)
    }

    private var axisDates: [Date] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        return [6, 12, 18].compactMap {
            calendar.date(byAdding: .hour, value: $0, to: dayStart)
        }
    }

    private func barWidth(for period: ForecastPeriod, availableWidth: CGFloat) -> CGFloat {
        let clippedStart = max(period.startTime, dayStart)
        let clippedEnd = min(period.endTime, dayEnd)
        return availableWidth * max(clippedEnd.timeIntervalSince(clippedStart), 0) / dayDuration
    }

    private func periodCenterX(for period: ForecastPeriod, availableWidth: CGFloat) -> CGFloat {
        let clippedStart = max(period.startTime, dayStart)
        let startOffset = clippedStart.timeIntervalSince(dayStart) / dayDuration
        return availableWidth * startOffset
            + barWidth(for: period, availableWidth: availableWidth) / 2
    }

    private func rawVolume(for period: ForecastPeriod) -> Double {
        rawAmounts.precipitationVolume(during: period) ?? 0
    }

    private func expectedVolume(for period: ForecastPeriod) -> Double {
        expectedAmounts.precipitationVolume(during: period) ?? 0
    }

    private func expectedPoints(
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> [CGPoint] {
        guard dayPeriods.contains(where: {
            expectedAmounts.precipitationVolume(during: $0) != nil
        }) else { return [] }

        return dayPeriods.map { period in
            let fraction = min(max(expectedVolume(for: period) / scaleMaximumMillimeters, 0), 1)
            return CGPoint(
                x: periodCenterX(for: period, availableWidth: availableWidth),
                y: availableHeight * (1 - fraction)
            )
        }
    }

    private func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let previous = index > 0 ? points[index - 1] : start
            let next = index + 2 < points.count ? points[index + 2] : end
            path.addCurve(
                to: end,
                control1: CGPoint(
                    x: start.x + (end.x - previous.x) / 6,
                    y: start.y + (end.y - previous.y) / 6
                ),
                control2: CGPoint(
                    x: end.x - (next.x - start.x) / 6,
                    y: end.y - (next.y - start.y) / 6
                )
            )
        }
        return path
    }

    private func axisX(for date: Date, availableWidth: CGFloat) -> CGFloat {
        let offset = date.timeIntervalSince(dayStart) / dayDuration
        return availableWidth * min(max(offset, 0), 1)
    }

    private var expectedPrecipitationGradient: LinearGradient {
        LinearGradient(
            colors: [
                ForecastPalette.expectedPrecipitationStart,
                ForecastPalette.expectedPrecipitation
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func formattedTime(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    private func formattedScaleAmount(_ millimeters: Double) -> String {
        if unit == .celsius {
            if millimeters < 0.1 { return String(format: "%.2fmm", millimeters) }
            if millimeters < 1 { return String(format: "%.1fmm", millimeters) }
            if millimeters < 10 { return String(format: "%.1fmm", millimeters) }
            return String(format: "%.0fmm", millimeters)
        }

        let inches = millimeters / 25.4
        if inches < 0.01 { return String(format: "%.3f\"", inches) }
        if inches < 0.1 { return String(format: "%.2f\"", inches) }
        if inches < 1 { return String(format: "%.1f\"", inches) }
        return String(format: "%.0f\"", inches)
    }

}

private struct DailyIconTransition: View {
    let row: DailyForecastRow
    let precipitationAmounts: [PrecipitationAmount]
    let unit: TemperatureUnit
    let precipitationVolumeRepresentation: PrecipitationVolumeRepresentation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let daytime = row.daytime {
                weatherIcon(label: "Day", period: daytime)
            }

            if row.daytime != nil, row.nighttime != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ForecastPalette.secondary.opacity(0.65))
                    .frame(height: 40)
                    .accessibilityHidden(true)
            }

            if let nighttime = row.nighttime {
                weatherIcon(label: "Night", period: nighttime)
            }
        }
    }

    private func weatherIcon(label: String, period: ForecastPeriod) -> some View {
        VStack(spacing: 2) {
            Image(systemName: period.symbolName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    period.weatherTint,
                    period.weatherSecondaryTint,
                    period.weatherTertiaryTint
                )
                .font(.system(size: 32))
                .frame(width: 40, height: 40)

            Label(
                "\(formattedVolume(during: period)) (\(period.precipitationChance)%)",
                systemImage: "drop.fill"
            )
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(ForecastPalette.rainChance)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(width: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label), \(period.shortForecast), "
                + "\(period.precipitationChance) percent precipitation chance, "
                + "\(precipitationVolumeRepresentation.chartTitle.lowercased()) "
                + "\(accessibleVolume(during: period))"
        )
    }

    private func formattedVolume(during period: ForecastPeriod) -> String {
        compactPrecipitationVolume(precipitationVolume(during: period), unit: unit)
    }

    private func accessibleVolume(during period: ForecastPeriod) -> String {
        guard let millimeters = precipitationVolume(during: period) else {
            return "precipitation amount unavailable"
        }
        return PrecipitationAmount(
            startTime: period.startTime,
            endTime: period.endTime,
            millimeters: millimeters
        ).formattedAmount(for: unit) + " precipitation"
    }

    private func precipitationVolume(during period: ForecastPeriod) -> Double? {
        precipitationAmounts.precipitationVolume(during: period)
    }
}

private extension Array where Element == PrecipitationAmount {
    func precipitationVolume(during period: ForecastPeriod) -> Double? {
        var foundCoverage = false
        let total = reduce(0.0) { total, amount in
            let overlapStart = Swift.max(period.startTime, amount.startTime)
            let overlapEnd = Swift.min(period.endTime, amount.endTime)
            guard overlapEnd > overlapStart else { return total }

            foundCoverage = true
            let duration = amount.endTime.timeIntervalSince(amount.startTime)
            guard duration > 0 else { return total }
            let overlapFraction = overlapEnd.timeIntervalSince(overlapStart) / duration
            return total + amount.millimeters * overlapFraction
        }
        return foundCoverage ? total : nil
    }
}

private func compactPrecipitationVolume(
    _ millimeters: Double?,
    unit: TemperatureUnit
) -> String {
    guard let millimeters else { return "—" }

    if unit == .celsius {
        if millimeters == 0 { return "0mm" }
        if millimeters < 0.1 { return "<.1mm" }
        if millimeters < 10 { return String(format: "%.1fmm", millimeters) }
        return String(format: "%.0fmm", millimeters)
    }

    let inches = millimeters / 25.4
    if inches == 0 { return "0\"" }
    if inches < 0.01 { return "<.01\"" }
    if inches < 1 {
        return String(format: "%.2f\"", inches)
            .replacingOccurrences(of: "0.", with: ".")
    }
    return String(format: "%.1f\"", inches)
}

private struct DailyTemperaturePair: View {
    let row: DailyForecastRow
    let unit: TemperatureUnit

    var body: some View {
        HStack(spacing: 8) {
            if let daytime = row.daytime {
                temperature(
                    label: "High",
                    icon: "thermometer.high",
                    period: daytime,
                    color: .orange
                )
            }
            if let nighttime = row.nighttime {
                temperature(
                    label: "Low",
                    icon: "thermometer.low",
                    period: nighttime,
                    color: ForecastPalette.lowTemperature
                )
            }
        }
    }

    private func temperature(
        label: String,
        icon: String,
        period: ForecastPeriod,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ForecastPalette.secondary)
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .frame(width: 10)
                    .accessibilityHidden(true)
                Text("\(period.temperature(in: unit))°")
                    .font(.headline.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 58, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ConditionsGrid: View {
    let snapshot: WeatherSnapshot
    let unit: TemperatureUnit
    let altitudeUnit: AltitudeUnit

    var body: some View {
        let observation = snapshot.observation
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                MetricTile(title: "Humidity", value: observation?.relativeHumidity.value.map { "\(Int($0))%" } ?? "—", icon: "humidity.fill")
                MetricTile(title: "Dew point", value: observation?.dewpoint.temperature(in: unit).map { "\($0)°" } ?? "—", icon: "thermometer.medium")
            }
            GridRow {
                MetricTile(title: "Wind", value: observation?.windSpeed.milesPerHour.map { String(format: "%.0f mph", $0) } ?? snapshot.hourly.first?.windSpeed ?? "—", icon: "wind")
                MetricTile(title: "Visibility", value: observation?.visibility.miles.map { String(format: "%.1f mi", $0) } ?? "—", icon: "eye.fill")
            }
            GridRow {
                MetricTile(title: "Pressure", value: observation?.barometricPressure.hectopascals.map { String(format: "%.0f hPa", $0) } ?? "—", icon: "gauge.with.dots.needle.50percent")
                MetricTile(
                    title: "Altitude",
                    value: snapshot.location.elevation?.formatted(for: altitudeUnit) ?? "—",
                    icon: "mountain.2.fill"
                )
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(ForecastPalette.secondary)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard()
        .foregroundStyle(ForecastPalette.ink)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func glassCard() -> some View {
        background(ForecastPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(ForecastPalette.cardBorder)
            )
            .shadow(color: ForecastPalette.shadow, radius: 14, y: 6)
    }
}

private enum ForecastPalette {
    static let ink = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let blue = adaptive(
        light: UIColor(red: 0.02, green: 0.42, blue: 0.76, alpha: 1),
        dark: UIColor(red: 0.32, green: 0.7, blue: 1, alpha: 1)
    )
    static let precipitation = adaptive(
        light: UIColor(red: 0.28, green: 0.66, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.4, green: 0.78, blue: 1, alpha: 1)
    )
    static let expectedPrecipitation = adaptive(
        light: UIColor(red: 0.03, green: 0.68, blue: 0.76, alpha: 1),
        dark: UIColor(red: 0.26, green: 0.9, blue: 0.94, alpha: 1)
    )
    static let expectedPrecipitationStart = adaptive(
        light: UIColor(red: 0.02, green: 0.49, blue: 0.76, alpha: 1),
        dark: UIColor(red: 0.2, green: 0.7, blue: 1, alpha: 1)
    )
    static let expectedPrecipitationGlow = adaptive(
        light: UIColor(red: 0.02, green: 0.63, blue: 0.79, alpha: 0.15),
        dark: UIColor(red: 0.24, green: 0.84, blue: 0.98, alpha: 0.2)
    )
    static let temperatureStart = adaptive(
        light: UIColor(red: 0.94, green: 0.25, blue: 0.42, alpha: 1),
        dark: UIColor(red: 1, green: 0.4, blue: 0.55, alpha: 1)
    )
    static let temperatureEnd = adaptive(
        light: UIColor(red: 1, green: 0.55, blue: 0.22, alpha: 1),
        dark: UIColor(red: 1, green: 0.68, blue: 0.3, alpha: 1)
    )
    static let temperatureGlow = adaptive(
        light: UIColor(red: 0.98, green: 0.34, blue: 0.38, alpha: 0.16),
        dark: UIColor(red: 1, green: 0.5, blue: 0.4, alpha: 0.22)
    )
    static let lowTemperature = adaptive(
        light: UIColor(red: 0.34, green: 0.29, blue: 0.7, alpha: 1),
        dark: UIColor(red: 0.68, green: 0.62, blue: 1, alpha: 1)
    )
    static let rainChance = adaptive(
        light: UIColor(red: 0, green: 0.47, blue: 0.56, alpha: 1),
        dark: UIColor(red: 0.3, green: 0.82, blue: 0.86, alpha: 1)
    )
    static let badgeBackground = adaptive(
        light: UIColor(red: 0.08, green: 0.15, blue: 0.24, alpha: 0.88),
        dark: UIColor(red: 0.08, green: 0.24, blue: 0.36, alpha: 0.96)
    )
    static let card = adaptive(
        light: UIColor(white: 1, alpha: 0.88),
        dark: UIColor(red: 0.075, green: 0.105, blue: 0.14, alpha: 0.88)
    )
    static let cardBorder = adaptive(
        light: UIColor(white: 1, alpha: 0.9),
        dark: UIColor(white: 1, alpha: 0.14)
    )
    static let grid = adaptive(
        light: UIColor(red: 0.58, green: 0.66, blue: 0.73, alpha: 0.35),
        dark: UIColor(red: 0.6, green: 0.72, blue: 0.82, alpha: 0.28)
    )
    static let shadow = adaptive(
        light: UIColor(red: 0.12, green: 0.3, blue: 0.45, alpha: 0.12),
        dark: UIColor(white: 0, alpha: 0.38)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}
