import UIKit
import XCTest

final class DrashUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            let allow = alert.buttons["Allow While Using App"]
            if allow.exists {
                allow.tap()
                return true
            }
            return false
        }
        app.launch()
        app.tap()
        let incidentalAlertSheetDone = app.buttons["Done"]
        if incidentalAlertSheetDone.waitForExistence(timeout: 1) {
            incidentalAlertSheetDone.tap()
        }
    }

    func testIPadAdaptiveNavigationAndCoreScreens() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad-only adaptive layout coverage")
        }

        let forecast = app.buttons["Forecast"].firstMatch
        let radar = app.buttons["Radar"].firstMatch
        let places = app.buttons["Places"].firstMatch
        let settings = app.buttons["Settings"].firstMatch

        XCTAssertTrue(forecast.waitForExistence(timeout: 10))
        XCTAssertTrue(radar.exists)
        XCTAssertTrue(places.exists)
        XCTAssertTrue(settings.exists)

        places.tap()
        XCTAssertTrue(app.navigationBars["Places"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["City, park, crag, summit, or ZIP code"].exists)

        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fahrenheit"].exists)

        forecast.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    func testRainVolumeRepresentationSetting() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Settings"].tap()

        let expectedPrecipitation = app.buttons["Expected"]
        let rawPrecipitationVolume = app.buttons["Raw volume"]
        XCTAssertTrue(expectedPrecipitation.waitForExistence(timeout: 5))
        expectedPrecipitation.tap()
        XCTAssertTrue(expectedPrecipitation.isSelected)

        app.buttons["About rain volume representation"].tap()
        XCTAssertTrue(app.alerts["Rain volume representation"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "weights the model volume")
            ).firstMatch.exists
        )
        app.alerts["Rain volume representation"].buttons["OK"].tap()

        rawPrecipitationVolume.tap()
        XCTAssertTrue(rawPrecipitationVolume.isSelected)

        tabBar.buttons["Forecast"].tap()
        let hourlySummary = app.buttons["Next 24 hours"]
        XCTAssertTrue(hourlySummary.waitForExistence(timeout: 35))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                    "percent precipitation chance",
                    "precipitation volume"
                )
            ).firstMatch.waitForExistence(timeout: 5)
        )
        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        for _ in 0..<5 where !hourlySummary.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlySummary.isHittable)
        hourlySummary.tap()
        XCTAssertTrue(app.staticTexts["Volume"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Expected"].exists)

        tabBar.buttons["Settings"].tap()
        XCTAssertTrue(expectedPrecipitation.waitForExistence(timeout: 5))
        expectedPrecipitation.tap()
        XCTAssertTrue(expectedPrecipitation.isSelected)
    }

    func testDailyPrecipitationHistogramVisible() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Places"].tap()

        let search = app.searchFields["City, park, crag, summit, or ZIP code"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Indianapolis, IN")

        let indianapolis = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Indianapolis")
        ).firstMatch
        XCTAssertTrue(indianapolis.waitForExistence(timeout: 20))
        indianapolis.tap()
        XCTAssertTrue(tabBar.buttons["Forecast"].isSelected)
        XCTAssertTrue(
            app.navigationBars.matching(
                NSPredicate(format: "identifier CONTAINS[c] %@", "Indianapolis")
            ).firstMatch.waitForExistence(timeout: 35)
        )

        let histogramMode = app.buttons["Histogram"]
        let histogram = app.descendants(matching: .any)
            .matching(identifier: "daily-precipitation-histogram")
            .firstMatch
        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        XCTAssertTrue(forecastScrollView.waitForExistence(timeout: 10))

        for _ in 0..<8 where !histogramMode.exists {
            forecastScrollView.swipeUp(velocity: .slow)
        }

        XCTAssertTrue(histogramMode.waitForExistence(timeout: 35))
        histogramMode.tap()
        XCTAssertTrue(histogram.waitForExistence(timeout: 35))
        let histogramLabel = histogram.label.lowercased()
        XCTAssertTrue(histogramLabel.contains("blue bars show precipitation volume"))
        XCTAssertTrue(histogramLabel.contains("cyan line shows expected precipitation"))

        for (modelName, modelID) in [("NWS", "nws"), ("HRRR", "hrrr")] {
            let modelButton = app.buttons[modelName]
            XCTAssertTrue(modelButton.waitForExistence(timeout: 10))
            if !modelButton.isSelected {
                modelButton.tap()
            }
            XCTAssertTrue(modelButton.isSelected)
            XCTAssertTrue(
                app.staticTexts["daily-forecast-heading-\(modelID)"]
                    .waitForExistence(timeout: 35)
            )
            XCTAssertTrue(histogram.waitForExistence(timeout: 10))

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Visible \(modelName) daily precipitation histogram"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        let forecastInfo = app.buttons["About forecast models and histogram"]
        XCTAssertTrue(forecastInfo.waitForExistence(timeout: 5))
        for _ in 0..<5 where !forecastInfo.isHittable {
            forecastScrollView.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(forecastInfo.isHittable)
        forecastInfo.tap()
        XCTAssertTrue(app.staticTexts["Histogram key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Precipitation volume"].exists)
        XCTAssertTrue(app.staticTexts["Expected precipitation"].exists)
    }

    func testHourlyForecastScrollMovesTimelineSelection() throws {
        let hourlySummary = app.buttons["Next 24 hours"]
        XCTAssertTrue(hourlySummary.waitForExistence(timeout: 35))

        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        XCTAssertTrue(forecastScrollView.waitForExistence(timeout: 5))
        for _ in 0..<5 where !hourlySummary.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlySummary.isHittable)
        hourlySummary.tap()

        let hourlyStrip = app.scrollViews["hourly-forecast-strip"].firstMatch
        XCTAssertTrue(hourlyStrip.waitForExistence(timeout: 5))
        XCTAssertTrue(hourlyStrip.isHittable)

        let chart = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertEqual(chart.value as? String, "No time selected")

        hourlyStrip.swipeLeft()
        let synchronizedSelection = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (chart.value as? String)?.contains("Selected") == true
            },
            object: chart
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [synchronizedSelection], timeout: 3),
            .completed
        )

        let centeredHourBeforeChartSelection = hourlyStrip.value as? String
        for _ in 0..<6 where !chart.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(chart.isHittable)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.55)).tap()

        let synchronizedForecastStrip = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let centeredHour = hourlyStrip.value as? String else { return false }
                return centeredHour.hasPrefix("Centered hour")
                    && centeredHour != centeredHourBeforeChartSelection
            },
            object: hourlyStrip
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [synchronizedForecastStrip], timeout: 3),
            .completed
        )
    }

    func testDailyDetailShowsFullTemperatureAndPrecipitationTimeline() throws {
        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        XCTAssertTrue(forecastScrollView.waitForExistence(timeout: 35))

        var firstDailyForecast = app.buttons.matching(
            NSPredicate(format: "identifier MATCHES %@", "daily-forecast-[0-9]+")
        ).firstMatch
        for _ in 0..<10 where !firstDailyForecast.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
            firstDailyForecast = app.buttons.matching(
                NSPredicate(format: "identifier MATCHES %@", "daily-forecast-[0-9]+")
            ).firstMatch
        }
        XCTAssertTrue(firstDailyForecast.isHittable)
        firstDailyForecast.coordinate(
            withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)
        ).tap()
        XCTAssertTrue(app.staticTexts["Detailed forecast"].waitForExistence(timeout: 5))

        let hourlyStrip = app.scrollViews["hourly-forecast-strip"].firstMatch
        for _ in 0..<8 where !hourlyStrip.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlyStrip.isHittable)

        let synchronizedChart = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        XCTAssertTrue(synchronizedChart.waitForExistence(timeout: 5))
        hourlyStrip.swipeLeft()
        let synchronizedSelection = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (synchronizedChart.value as? String)?.contains("Selected") == true
            },
            object: synchronizedChart
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [synchronizedSelection], timeout: 3),
            .completed
        )

        let hourlyTimeline = app.staticTexts["Hourly timeline"]
        for _ in 0..<8 where !hourlyTimeline.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlyTimeline.isHittable)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Temperature ")
            ).firstMatch.exists
        )
        XCTAssertTrue(app.staticTexts["Volume"].exists)
        XCTAssertTrue(app.staticTexts["Expected"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "temperature-precipitation-chart")
                .firstMatch.exists
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Full daily temperature and precipitation timeline"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testForecastFavoritesUnitsRadarPlacesAndCacheRelaunch() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertTrue(tabBar.buttons["Forecast"].exists)
        XCTAssertTrue(tabBar.buttons["Radar"].exists)
        XCTAssertTrue(tabBar.buttons["Places"].exists)
        XCTAssertTrue(tabBar.buttons["Settings"].exists)

        let savePlace = app.buttons["Save place"]
        let savedPlace = app.buttons["Saved place"]
        XCTAssertTrue(savePlace.waitForExistence(timeout: 35) || savedPlace.exists)
        if savePlace.exists {
            savePlace.tap()
            XCTAssertTrue(savedPlace.waitForExistence(timeout: 3))
        }

        tabBar.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Forecasts & alerts"].waitForExistence(timeout: 5))
        app.buttons["Celsius"].tap()
        XCTAssertTrue(app.buttons["Celsius"].isSelected)

        tabBar.buttons["Forecast"].tap()
        XCTAssertTrue(app.staticTexts["Temperature °C"].waitForExistence(timeout: 35))

        let hourlySummary = app.buttons["Next 24 hours"]
        XCTAssertTrue(hourlySummary.waitForExistence(timeout: 5))
        for _ in 0..<3 where !hourlySummary.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlySummary.isHittable)
        hourlySummary.tap()

        let combinedChart = app.staticTexts["24-hour forecast"]
        XCTAssertTrue(combinedChart.waitForExistence(timeout: 5))
        XCTAssertTrue(combinedChart.exists)
        XCTAssertTrue(app.staticTexts["precipitation-chart-legend"].exists)
        let precipitationDetail = app.staticTexts["Precipitation detail"]
        XCTAssertTrue(precipitationDetail.exists)
        XCTAssertTrue(app.staticTexts["Expected precipitation"].exists)

        let chartScreenshot = XCTAttachment(screenshot: app.screenshot())
        chartScreenshot.name = "Combined temperature and precipitation chart"
        chartScreenshot.lifetime = .keepAlways
        add(chartScreenshot)

        for _ in 0..<2 where !precipitationDetail.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(precipitationDetail.exists)
        let amountAvailable = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "hour total")
        ).firstMatch.exists
        let amountUnavailable = app.staticTexts["Accumulation forecast temporarily unavailable"].exists
        XCTAssertTrue(amountAvailable || amountUnavailable)

        for _ in 0..<4 where !hourlySummary.isHittable {
            app.swipeDown(velocity: .slow)
        }
        hourlySummary.tap()

        let defaultHRRR = app.buttons["HRRR"]
        let nwsDaily = app.buttons["NWS"]
        for _ in 0..<4 where !defaultHRRR.exists {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(defaultHRRR.waitForExistence(timeout: 5))
        if defaultHRRR.isSelected {
            nwsDaily.tap()
        }

        let dailyForecast = app.staticTexts["7-day forecast"]
        for _ in 0..<3 where !dailyForecast.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(dailyForecast.waitForExistence(timeout: 35))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Day,"))
                .firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Night,"))
                .firstMatch.waitForExistence(timeout: 3)
        )
        app.buttons["Histogram"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "daily-precipitation-histogram")
                .firstMatch.waitForExistence(timeout: 10)
        )

        let precipitationScreenshot = XCTAttachment(screenshot: app.screenshot())
        precipitationScreenshot.name = "Precipitation detail and grouped daily forecast"
        precipitationScreenshot.lifetime = .keepAlways
        add(precipitationScreenshot)

        let firstDailyForecast = app.buttons.matching(
            NSPredicate(format: "identifier MATCHES %@", "daily-forecast-[0-9]+")
        ).firstMatch
        XCTAssertTrue(firstDailyForecast.waitForExistence(timeout: 5))
        for _ in 0..<3 where !firstDailyForecast.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(firstDailyForecast.isHittable)
        firstDailyForecast.tap()
        XCTAssertTrue(app.staticTexts["Detailed forecast"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Day"].exists || app.staticTexts["Night"].exists
        )
        let hourlyTimeline = app.staticTexts["Hourly timeline"]
        for _ in 0..<8 where !hourlyTimeline.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlyTimeline.isHittable)
        XCTAssertTrue(app.staticTexts["Volume"].exists)
        XCTAssertTrue(app.staticTexts["Expected"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "temperature-precipitation-chart")
                .firstMatch.exists
        )
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["7-day forecast"].waitForExistence(timeout: 5))

        tabBar.buttons["Places"].tap()
        XCTAssertTrue(app.buttons["My Location"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["City, park, crag, summit, or ZIP code"].exists)
        XCTAssertTrue(app.buttons["Refresh outdoor places"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Forecast"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Temperature °C"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Loading National Weather Service data…"].exists)

        app.tabBars.buttons["Radar"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        let radarSourceSwitcher = app.buttons["radar-source-switcher"]
        XCTAssertTrue(radarSourceSwitcher.waitForExistence(timeout: 5))
        XCTAssertEqual(radarSourceSwitcher.value as? String, "NWS")
        XCTAssertTrue(app.buttons["Center radar on GPS location"].exists)
        XCTAssertTrue(app.buttons["Center radar on forecast location"].exists)
        XCTAssertTrue(app.buttons["Refresh radar"].exists)
        XCTAssertTrue(app.buttons["Radar options"].exists)
        XCTAssertFalse(app.sliders["Radar opacity"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["precipitation-intensity-legend"].exists)

        XCTAssertTrue(app.sliders["Radar time"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Radar connection unavailable"].exists)
        XCTAssertEqual(radarSourceSwitcher.value as? String, "NWS")
        XCTAssertTrue(app.staticTexts["Latest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play radar"].exists)
        XCTAssertTrue(app.buttons["Previous radar frame"].exists)
        app.buttons["Previous radar frame"].tap()
        XCTAssertTrue(app.buttons["Next radar frame"].isEnabled)

        radarSourceSwitcher.tap()
        app.buttons["HRRR"].tap()
        XCTAssertTrue(app.staticTexts["+18 hours"].waitForExistence(timeout: 30))

        radarSourceSwitcher.tap()
        app.buttons["NWS"].tap()
        XCTAssertTrue(app.staticTexts["Past 2 hours"].waitForExistence(timeout: 30))

        app.buttons["Radar options"].tap()
        XCTAssertTrue(app.buttons["Adjust radar opacity"].waitForExistence(timeout: 3))
        app.buttons["Adjust radar opacity"].tap()
        XCTAssertTrue(app.sliders["Radar opacity"].waitForExistence(timeout: 3))

        let radarScreenshot = XCTAttachment(screenshot: app.screenshot())
        radarScreenshot.name = "Native NWS radar"
        radarScreenshot.lifetime = .keepAlways
        add(radarScreenshot)
    }

    func testSavedPlacePersistsAcrossRelaunch() throws {
        let savePlace = app.buttons["Save place"]
        let savedPlace = app.buttons["Saved place"]
        XCTAssertTrue(savePlace.waitForExistence(timeout: 35) || savedPlace.exists)

        if savedPlace.exists {
            savedPlace.tap()
            XCTAssertTrue(savePlace.waitForExistence(timeout: 3))
        }

        savePlace.tap()
        XCTAssertTrue(savedPlace.waitForExistence(timeout: 3))

        app.terminate()
        app.launch()

        XCTAssertTrue(savedPlace.waitForExistence(timeout: 15))
    }

    func testInteractiveMeteogramTimeIndicator() throws {
        let hourlySummary = app.buttons["Next 24 hours"]
        XCTAssertTrue(hourlySummary.waitForExistence(timeout: 35))
        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        XCTAssertTrue(forecastScrollView.waitForExistence(timeout: 3))
        for _ in 0..<4 where !hourlySummary.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlySummary.isHittable)
        hourlySummary.tap()

        let chartHeading = app.staticTexts["24-hour forecast"]
        XCTAssertTrue(chartHeading.waitForExistence(timeout: 5))
        for _ in 0..<6 where !chartHeading.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        let chart = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Volume"].exists)
        XCTAssertTrue(app.staticTexts["Expected"].exists)
        for _ in 0..<6 where !chart.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(chart.isHittable)

        let initialValue = chart.value as? String
        XCTAssertEqual(initialValue, "No time selected")

        let verticalDragStart = chart.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)
        )
        let verticalDragEnd = chart.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)
        )
        let chartMinYBeforeVerticalDrag = chart.frame.minY
        verticalDragStart.press(forDuration: 0.05, thenDragTo: verticalDragEnd)

        let chartAfterVerticalDrag = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        XCTAssertEqual(
            chartAfterVerticalDrag.value as? String,
            "No time selected",
            "A vertical drag should remain available to the detail view instead of selecting a chart time"
        )
        XCTAssertLessThan(
            chartAfterVerticalDrag.frame.minY,
            chartMinYBeforeVerticalDrag - 20,
            "A vertical drag over the chart should continue scrolling the forecast"
        )

        chartAfterVerticalDrag.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55)).tap()
        let tappedChart = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        let tappedValue = tappedChart.value as? String
        XCTAssertTrue(tappedValue?.contains("Selected") == true)

        let start = tappedChart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55))
        let end = tappedChart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)

        let updatedChart = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        let selectedValue = updatedChart.value as? String
        XCTAssertNotEqual(tappedValue, selectedValue)
        XCTAssertTrue(selectedValue?.contains("Selected") == true)
        XCTAssertTrue(selectedValue?.contains("temperature") == true)
        XCTAssertTrue(selectedValue?.contains("expected precipitation") == true)

        let selectedValueScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectedValueScreenshot.name = "Sliding chart time indicator"
        selectedValueScreenshot.lifetime = .keepAlways
        add(selectedValueScreenshot)

        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let currentChart = self.app.descendants(matching: .any)
                .matching(identifier: "temperature-precipitation-chart")
                .firstMatch
            return currentChart.value as? String == "No time selected"
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 12), .completed)

        for _ in 0..<6 where !hourlySummary.isHittable {
            forecastScrollView.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(hourlySummary.isHittable)
        hourlySummary.tap()
        XCTAssertEqual(hourlySummary.value as? String, "Collapsed")

        hourlySummary.tap()
        XCTAssertEqual(hourlySummary.value as? String, "Expanded")
    }

    func testMyLocationIsAlwaysAvailableAsSavedPlace() throws {
        let placesTab = app.tabBars.buttons["Places"]
        XCTAssertTrue(placesTab.waitForExistence(timeout: 10))
        placesTab.tap()

        let myLocation = app.buttons["My Location"]
        XCTAssertTrue(myLocation.waitForExistence(timeout: 5))
    }

    func testOfflineOutdoorCatalogSearch() throws {
        let placesTab = app.tabBars.buttons["Places"]
        XCTAssertTrue(placesTab.waitForExistence(timeout: 10))
        placesTab.tap()

        let searchField = app.searchFields["City, park, crag, summit, or ZIP code"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "outdoor places")
        ).firstMatch.exists)

        searchField.tap()
        searchField.typeText("Mount Elbert")
        XCTAssertTrue(app.staticTexts["Mount Elbert"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["14er · 14,440 ft · CO"].exists)
    }

    func testOfflineParkCatalogSearch() throws {
        let placesTab = app.tabBars.buttons["Places"]
        XCTAssertTrue(placesTab.waitForExistence(timeout: 10))
        placesTab.tap()

        let searchField = app.searchFields["City, park, crag, summit, or ZIP code"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Yellowstone National Park")
        XCTAssertTrue(app.staticTexts["Yellowstone National Park"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["National park · WY"].exists)
    }

    func testOfflineStateParkCatalogSearch() throws {
        let placesTab = app.tabBars.buttons["Places"]
        XCTAssertTrue(placesTab.waitForExistence(timeout: 10))
        placesTab.tap()

        let searchField = app.searchFields["City, park, crag, summit, or ZIP code"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Castlewood Canyon State Park")
        XCTAssertTrue(app.staticTexts["Castlewood Canyon State Park"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["State park · CO"].exists)
    }

    func testRadarObservedHistory() throws {
        let radarTab = app.tabBars.buttons["Radar"]
        XCTAssertTrue(radarTab.waitForExistence(timeout: 10))
        radarTab.tap()

        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        let timeline = app.sliders["Radar time"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Radar connection unavailable"].exists)

        let radarSourceSwitcher = app.buttons["radar-source-switcher"]
        XCTAssertTrue(radarSourceSwitcher.exists)
        XCTAssertEqual(radarSourceSwitcher.value as? String, "NWS")
        XCTAssertTrue(app.staticTexts["Past 2 hours"].exists)
        XCTAssertTrue(app.staticTexts["Latest"].exists)
        XCTAssertTrue(app.staticTexts["NOAA · National Weather Service"].exists)
        XCTAssertFalse(app.staticTexts["+1 hour"].exists)

        radarSourceSwitcher.tap()
        app.buttons["HRRR"].tap()
        XCTAssertTrue(app.staticTexts["+18 hours"].waitForExistence(timeout: 30))
        XCTAssertEqual(radarSourceSwitcher.value as? String, "HRRR")
        XCTAssertTrue(app.staticTexts["NOAA HRRR · Iowa State IEM"].exists)

        radarSourceSwitcher.tap()
        app.buttons["NWS"].tap()
        XCTAssertTrue(app.staticTexts["Past 2 hours"].waitForExistence(timeout: 30))

        let previousFrame = app.buttons["Previous radar frame"]
        let nextFrame = app.buttons["Next radar frame"]
        let sliderLeftOutside = timeline.coordinate(
            withNormalizedOffset: CGVector(dx: -0.25, dy: 0.5)
        )
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: sliderLeftOutside,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        XCTAssertFalse(previousFrame.isEnabled, "Radar timeline should stop at its first frame")

        let sliderRightOutside = timeline.coordinate(
            withNormalizedOffset: CGVector(dx: 1.25, dy: 0.5)
        )
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: sliderRightOutside,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        XCTAssertFalse(nextFrame.isEnabled, "Radar timeline should stop at its latest frame")

        let precipitationLegend = app.descendants(matching: .any)["precipitation-intensity-legend"]
        XCTAssertFalse(precipitationLegend.exists)

        app.buttons["Radar options"].tap()
        XCTAssertTrue(app.buttons["Show precipitation legend"].waitForExistence(timeout: 3))
        app.buttons["Show precipitation legend"].tap()
        XCTAssertTrue(precipitationLegend.waitForExistence(timeout: 3))

        app.buttons["Radar options"].tap()
        XCTAssertTrue(app.buttons["Hide precipitation legend"].waitForExistence(timeout: 3))
        app.buttons["Hide precipitation legend"].tap()
        XCTAssertTrue(precipitationLegend.waitForNonExistence(timeout: 3))

        let latestTimelineValue = timeline.value as? String
        let sliderStart = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let sliderEnd = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        sliderStart.press(
            forDuration: 0.15,
            thenDragTo: sliderEnd,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        let timelineMoved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (timeline.value as? String) != latestTimelineValue
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [timelineMoved], timeout: 5), .completed)
        let frameLoading = app.activityIndicators["Loading radar frame"]
        _ = frameLoading.waitForExistence(timeout: 2)
        XCTAssertTrue(frameLoading.waitForNonExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Pause or release to load frame"].exists)
        XCTAssertEqual(radarSourceSwitcher.value as? String, "NWS")

        let historyScreenshot = XCTAttachment(screenshot: app.screenshot())
        historyScreenshot.name = "Observed NWS radar history"
        historyScreenshot.lifetime = .keepAlways
        add(historyScreenshot)

        app.buttons["Play radar"].tap()
        XCTAssertTrue(app.buttons["Pause radar"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Forecast"].tap()
        app.tabBars.buttons["Radar"].tap()
        XCTAssertTrue(app.buttons["Play radar"].waitForExistence(timeout: 3))

        let observedScreenshot = XCTAttachment(screenshot: app.screenshot())
        observedScreenshot.name = "Observed radar after playback"
        observedScreenshot.lifetime = .keepAlways
        add(observedScreenshot)
    }

    func testPullToRefreshReturnsForecastToTop() throws {
        let scrollView = app.scrollViews["forecast-scroll-view"]
        let currentConditions = app.descendants(matching: .any)["current-conditions-card"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 35))
        XCTAssertTrue(currentConditions.waitForExistence(timeout: 5))
        let restingMinY = currentConditions.frame.minY

        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)

        let returnedToTop = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(currentConditions.frame.minY - restingMinY) < 1
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returnedToTop], timeout: 3), .completed)

        let remainedAtTop = expectation(description: "Forecast remains at its resting position")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { remainedAtTop.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [remainedAtTop], timeout: 2), .completed)
        XCTAssertLessThan(abs(currentConditions.frame.minY - restingMinY), 1)
    }

    func testPlaceSearchSelectsNewForecast() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Places"].tap()

        let search = app.searchFields["City, park, crag, summit, or ZIP code"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Laramie, WY")

        let result = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Laramie")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        result.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(tabBar.buttons["Forecast"].isSelected)

        let laramieForecast = app.navigationBars.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@", "Laramie")
        ).firstMatch
        XCTAssertTrue(laramieForecast.waitForExistence(timeout: 35))
        XCTAssertTrue(app.buttons["Save place"].waitForExistence(timeout: 5))

        tabBar.buttons["Places"].tap()
        let savedLaramie = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Laramie")
        ).firstMatch
        XCTAssertFalse(savedLaramie.exists)

        tabBar.buttons["Forecast"].tap()
        app.buttons["Save place"].tap()
        XCTAssertTrue(app.buttons["Saved place"].waitForExistence(timeout: 3))

        tabBar.buttons["Places"].tap()
        XCTAssertTrue(savedLaramie.waitForExistence(timeout: 5))
        savedLaramie.tap()
        XCTAssertTrue(tabBar.buttons["Forecast"].isSelected)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Forecast"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.navigationBars.matching(
                NSPredicate(format: "identifier CONTAINS[c] %@", "Laramie")
            ).firstMatch.waitForExistence(timeout: 35)
        )
    }

    func testColoradoFourteenerSearchUsesSummitElevation() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        tabBar.buttons["Settings"].tap()
        let meters = app.buttons["Meters"]
        XCTAssertTrue(meters.waitForExistence(timeout: 5))
        meters.tap()
        XCTAssertTrue(meters.isSelected)

        tabBar.buttons["Places"].tap()

        let search = app.searchFields["City, park, crag, summit, or ZIP code"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Mount Elbert")

        let mountElbert = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Mount Elbert")
        ).firstMatch
        XCTAssertTrue(mountElbert.waitForExistence(timeout: 5))
        mountElbert.tap()

        XCTAssertTrue(tabBar.buttons["Forecast"].isSelected)
        XCTAssertTrue(
            app.navigationBars.matching(
                NSPredicate(format: "identifier CONTAINS[c] %@", "Mount Elbert")
            ).firstMatch.waitForExistence(timeout: 35)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "HRRR downscaled to 4,401 m")
            ).firstMatch.waitForExistence(timeout: 5)
        )

        tabBar.buttons["Settings"].tap()
        let feet = app.buttons["Feet"]
        XCTAssertTrue(feet.waitForExistence(timeout: 5))
        feet.tap()
    }

    func testAutomaticHRRRHourlyAndDailyModelPersistsForPlace() throws {
        XCTAssertTrue(
            app.descendants(matching: .any)["current-conditions-card"]
                .waitForExistence(timeout: 35)
        )

        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        let nws = app.buttons["NWS"]
        let hrrr = app.buttons["HRRR"]
        let automaticHRRR = app.buttons["Next 24 hours"]
        XCTAssertTrue(automaticHRRR.waitForExistence(timeout: 5))
        for _ in 0..<4 where !automaticHRRR.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(automaticHRRR.isHittable)
        automaticHRRR.tap()
        XCTAssertEqual(automaticHRRR.value as? String, "Expanded")
        let chartHeading = app.staticTexts["24-hour forecast"]
        for _ in 0..<4 where !chartHeading.exists {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(chartHeading.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["HRRR · automatic"].exists)
        for _ in 0..<4 where !automaticHRRR.isHittable {
            forecastScrollView.swipeDown(velocity: .slow)
        }
        automaticHRRR.tap()

        for _ in 0..<6 where !nws.exists {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(nws.waitForExistence(timeout: 5))
        XCTAssertTrue(hrrr.exists)

        if !hrrr.isSelected {
            hrrr.tap()
            let defaultHRRRForecast = app.staticTexts["daily-forecast-heading-hrrr"]
            XCTAssertTrue(defaultHRRRForecast.waitForExistence(timeout: 35))
        }
        XCTAssertTrue(hrrr.isSelected)

        nws.tap()
        XCTAssertTrue(app.staticTexts["7-day forecast"].waitForExistence(timeout: 35))

        hrrr.tap()
        XCTAssertTrue(hrrr.isSelected)
        let hrrrDailyForecast = app.staticTexts["daily-forecast-heading-hrrr"]
        XCTAssertTrue(hrrrDailyForecast.waitForExistence(timeout: 35))
        XCTAssertFalse(app.alerts["Couldn’t update weather"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.scrollViews["forecast-scroll-view"].waitForExistence(timeout: 15))
        for _ in 0..<6 where !app.buttons["HRRR"].exists {
            app.scrollViews["forecast-scroll-view"].swipeUp(velocity: .slow)
        }
        XCTAssertTrue(app.buttons["HRRR"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["HRRR"].isSelected)

        app.buttons["NWS"].tap()
        XCTAssertTrue(app.staticTexts["7-day forecast"].waitForExistence(timeout: 35))
        XCTAssertTrue(app.buttons["NWS"].isSelected)
    }

    func testReadmeSanFranciscoFahrenheitScreenshots() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        tabBar.buttons["Places"].tap()
        XCTAssertTrue(app.buttons["My Location"].waitForExistence(timeout: 5))

        let search = app.searchFields["City, park, crag, summit, or ZIP code"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("San Francisco, CA")
        let sanFrancisco = app.buttons["place-search-result"].firstMatch
        XCTAssertTrue(sanFrancisco.waitForExistence(timeout: 20))
        sanFrancisco.tap()

        tabBar.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Fahrenheit"].waitForExistence(timeout: 5))
        app.buttons["Fahrenheit"].tap()

        tabBar.buttons["Forecast"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["current-conditions-card"]
                .waitForExistence(timeout: 35)
        )

        let forecastScreenshot = XCTAttachment(screenshot: app.screenshot())
        forecastScreenshot.name = "README San Francisco forecast Fahrenheit"
        forecastScreenshot.lifetime = .keepAlways
        add(forecastScreenshot)

        let hourlySummary = app.buttons["Next 24 hours"]
        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        XCTAssertTrue(hourlySummary.waitForExistence(timeout: 5))
        XCTAssertTrue(forecastScrollView.waitForExistence(timeout: 3))
        for _ in 0..<4 where !hourlySummary.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(hourlySummary.isHittable)
        hourlySummary.tap()

        let chartHeading = app.staticTexts["24-hour forecast"]
        XCTAssertTrue(chartHeading.waitForExistence(timeout: 5))
        for _ in 0..<4 where !chartHeading.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(chartHeading.isHittable)

        let chartScreenshot = XCTAttachment(screenshot: app.screenshot())
        chartScreenshot.name = "README San Francisco chart Fahrenheit"
        chartScreenshot.lifetime = .keepAlways
        add(chartScreenshot)

        tabBar.buttons["Radar"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.sliders["Radar time"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.sliders["Radar opacity"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["precipitation-intensity-legend"].exists)

        let radarScreenshot = XCTAttachment(screenshot: app.screenshot())
        radarScreenshot.name = "README San Francisco radar"
        radarScreenshot.lifetime = .keepAlways
        add(radarScreenshot)
    }
}
