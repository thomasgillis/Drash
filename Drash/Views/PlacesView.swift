import MapKit
import SwiftUI

struct PlacesView: View {
    let showForecast: () -> Void

    @Environment(\.dismissSearch) private var dismissSearch
    @EnvironmentObject private var model: WeatherViewModel
    @EnvironmentObject private var locationManager: LocationManager
    @StateObject private var searchService = PlaceSearchService()
    @StateObject private var outdoorCatalog = OutdoorCatalogStore()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let summitMatches = SummitCatalog.matching(query)
        let thirteenerMatches = outdoorCatalog.matchingThirteeners(query)
        let cragMatches = outdoorCatalog.matchingCrags(query)

        List {
            Section {
                Button {
                    Task { await outdoorCatalog.refresh() }
                } label: {
                    HStack {
                        Label("Refresh outdoor places", systemImage: "arrow.clockwise")
                        Spacer()
                        if outdoorCatalog.isRefreshing {
                            Text(
                                outdoorCatalog.refreshProgress,
                                format: .percent.precision(.fractionLength(0))
                            )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Download progress")
                                .accessibilityValue(
                                    Text(
                                        outdoorCatalog.refreshProgress,
                                        format: .percent.precision(.fractionLength(0))
                                    )
                                )
                        }
                    }
                }
                .disabled(outdoorCatalog.isRefreshing)

                if outdoorCatalog.isRefreshing {
                    ProgressView(value: outdoorCatalog.refreshProgress)
                        .accessibilityLabel("Outdoor-place catalog download")
                }

                if outdoorCatalog.entryCount > 0 {
                    Text(catalogSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = outdoorCatalog.refreshError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !query.isEmpty {
                if !summitMatches.isEmpty || !thirteenerMatches.isEmpty {
                    Section("Summits") {
                        ForEach(summitMatches.prefix(8)) { summit in
                            Button {
                                select(summit)
                            } label: {
                                SummitRow(summit: summit, altitudeUnit: model.altitudeUnit)
                            }
                        }
                        ForEach(thirteenerMatches) { summit in
                            Button {
                                select(summit)
                            } label: {
                                OutdoorSearchRow(result: summit, altitudeUnit: model.altitudeUnit)
                            }
                        }
                    }
                }

                if !cragMatches.isEmpty {
                    Section("Climbing areas") {
                        ForEach(cragMatches) { crag in
                            Button {
                                select(crag)
                            } label: {
                                OutdoorSearchRow(result: crag, altitudeUnit: model.altitudeUnit)
                            }
                        }
                    }
                }

                Section("Places") {
                    if searchService.isSearching {
                        HStack { ProgressView(); Text("Searching…") }
                    }
                    ForEach(searchService.results, id: \.self) { item in
                        Button {
                            select(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name ?? item.placemark.locality ?? "Place")
                                    .foregroundStyle(.primary)
                                Text([item.placemark.locality, item.placemark.administrativeArea]
                                    .compactMap { $0 }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("place-search-result")
                    }
                }
            }

            Section("Saved places") {
                Button {
                    selectCurrentLocation()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 28, height: 28)
                            .background(
                                Color(uiColor: .secondarySystemBackground),
                                in: Circle()
                            )
                            .overlay {
                                Circle().stroke(.blue.opacity(0.85), lineWidth: 1.25)
                            }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("My Location")
                                .foregroundStyle(.primary)
                            Text(currentLocationSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.selectedLocation?.isCurrentLocation == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .accessibilityLabel("My Location")
                .accessibilityHint("Shows weather at your current GPS position")

                if model.favoriteLocations.isEmpty {
                    Text("Search above or save a forecast to add more places.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.favoriteLocations) { location in
                        Button {
                            model.select(location)
                            showForecast()
                        } label: {
                            HStack(spacing: 12) {
                                SavedPlaceKindBadge(kind: location.kind)
                                VStack(alignment: .leading) {
                                    Text(location.displayName).foregroundStyle(.primary)
                                    Text(
                                        "Daily \(location.forecastModel.shortName) · "
                                            + (location.elevation.map {
                                                $0.formatted(for: model.altitudeUnit) + " · "
                                            } ?? "")
                                            + String(format: "%.3f, %.3f", location.latitude, location.longitude)
                                    )
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedLocation?.id == location.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    .onDelete(perform: model.removeFavorites)
                }
            }
        }
        .navigationTitle("Places")
        .searchable(text: $query, prompt: "City, crag, summit, or ZIP code")
        .searchFocused($searchFocused)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await searchService.search(query)
        }
    }

    private var catalogSummary: String {
        let count = outdoorCatalog.entryCount.formatted()
        if let date = outdoorCatalog.lastUpdated {
            return "\(count) crags and summits · Updated \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(count) crags and summits available offline"
    }

    private var currentLocationSubtitle: String {
        if let location = locationManager.currentLocation {
            return String(
                format: "Updates with GPS · %.3f, %.3f",
                location.coordinate.latitude,
                location.coordinate.longitude
            )
        }
        return "Updates with your GPS position"
    }

    private func selectCurrentLocation() {
        model.beginUsingDeviceLocation()
        if !locationManager.requestLocation() {
            model.cancelUsingDeviceLocation()
        }
        showForecast()
    }

    private func select(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        let location = WeatherLocation(
            name: item.name ?? item.placemark.locality ?? "Dropped pin",
            state: item.placemark.administrativeArea,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        model.select(location)
        query = ""
        searchFocused = false
        dismissSearch()
        showForecast()
    }

    private func select(_ summit: Summit) {
        model.select(summit.weatherLocation)
        query = ""
        searchFocused = false
        dismissSearch()
        showForecast()
    }

    private func select(_ result: OutdoorCatalogEntry) {
        model.select(result.weatherLocation)
        query = ""
        searchFocused = false
        dismissSearch()
        showForecast()
    }
}

private struct SummitRow: View {
    let summit: Summit
    let altitudeUnit: AltitudeUnit

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mountain.2.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(summit.name)
                    .foregroundStyle(.primary)
                Text(
                    "\(Elevation(feet: summit.elevationFeet, source: .summitCatalog).formatted(for: altitudeUnit)) · \(summit.range)"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OutdoorSearchRow: View {
    let result: OutdoorCatalogEntry
    let altitudeUnit: AltitudeUnit

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.kind == .crag ? "figure.climbing" : "mountain.2.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch result.kind {
        case .crag:
            return "Climbing area · \(result.state)"
        case .thirteener:
            let elevation = result.elevationFeet.map {
                Elevation(feet: $0, source: .terrainModel).formatted(for: altitudeUnit) + " · "
            } ?? ""
            return "13er · \(elevation)\(result.state)"
        }
    }
}

private struct SavedPlaceKindBadge: View {
    let kind: WeatherLocationKind

    var body: some View {
        Image(systemName: kind.savedPlaceSymbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(uiColor: kind.savedPlaceUIColor))
            .frame(width: 28, height: 28)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: Circle()
            )
            .overlay {
                Circle()
                    .stroke(
                        Color(uiColor: kind.savedPlaceUIColor).opacity(0.85),
                        lineWidth: 1.25
                    )
            }
            .accessibilityHidden(true)
    }
}

extension WeatherLocationKind {
    var savedPlaceSymbol: String {
        switch self {
        case .place: "building.2"
        case .crag: "figure.climbing"
        case .summit: "mountain.2"
        }
    }

    var savedPlaceUIColor: UIColor {
        switch self {
        case .place:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.58, green: 0.73, blue: 0.94, alpha: 1)
                    : UIColor(red: 0.32, green: 0.43, blue: 0.58, alpha: 1)
            }
        case .crag:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.53, green: 0.79, blue: 0.60, alpha: 1)
                    : UIColor(red: 0.32, green: 0.50, blue: 0.39, alpha: 1)
            }
        case .summit:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.91, green: 0.70, blue: 0.50, alpha: 1)
                    : UIColor(red: 0.57, green: 0.43, blue: 0.32, alpha: 1)
            }
        }
    }
}
