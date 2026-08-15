import MapKit
import SwiftUI

struct PlacesView: View {
    let showForecast: () -> Void

    @Environment(\.dismissSearch) private var dismissSearch
    @EnvironmentObject private var model: WeatherViewModel
    @EnvironmentObject private var locationManager: LocationManager
    @StateObject private var searchService = PlaceSearchService()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        List {
            Section {
                Button {
                    model.beginUsingDeviceLocation()
                    locationManager.requestLocation()
                    showForecast()
                } label: {
                    Label("Use current location", systemImage: "location.fill")
                }
            }

            if !query.isEmpty {
                Section("Search results") {
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
                    }
                }
            }

            Section("Saved places") {
                if model.favoriteLocations.isEmpty {
                    ContentUnavailableView(
                        "No saved places",
                        systemImage: "star",
                        description: Text("Search above or save the current forecast.")
                    )
                } else {
                    ForEach(model.favoriteLocations) { location in
                        Button {
                            model.select(location)
                            showForecast()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(location.displayName).foregroundStyle(.primary)
                                    Text(
                                        "Daily \(location.forecastModel.shortName) · "
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
        .searchable(text: $query, prompt: "City, town, or ZIP code")
        .searchFocused($searchFocused)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await searchService.search(query)
        }
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
}
