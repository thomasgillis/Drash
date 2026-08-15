import Foundation
import MapKit

@MainActor
final class PlaceSearchService: ObservableObject {
    @Published private(set) var results: [MKMapItem] = []
    @Published private(set) var isSearching = false

    private var activeSearch: MKLocalSearch?
    private var searchGeneration = UUID()

    func search(_ query: String) async {
        activeSearch?.cancel()
        searchGeneration = UUID()
        let generation = searchGeneration
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            results = []
            isSearching = false
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address]
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 45, longitudeDelta: 60)
        )
        let search = MKLocalSearch(request: request)
        activeSearch = search
        isSearching = true
        defer {
            if searchGeneration == generation { isSearching = false }
        }
        do {
            let newResults = try await search.start().mapItems.filter {
                $0.placemark.isoCountryCode == "US" || $0.placemark.isoCountryCode == "PR"
            }
            guard searchGeneration == generation else { return }
            results = newResults
        } catch is CancellationError {
            // A newer query replaced this one.
        } catch {
            guard searchGeneration == generation else { return }
            results = []
        }
    }
}
