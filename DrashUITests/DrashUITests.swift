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

        let combinedChart = app.staticTexts["24-hour forecast"]
        XCTAssertTrue(combinedChart.waitForExistence(timeout: 5))
        for _ in 0..<3 where !combinedChart.isHittable {
            app.swipeUp(velocity: .slow)
        }
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

        let dailyForecast = app.staticTexts["7-day forecast"]
        for _ in 0..<3 where !dailyForecast.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(dailyForecast.waitForExistence(timeout: 5))
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

        let precipitationScreenshot = XCTAttachment(screenshot: app.screenshot())
        precipitationScreenshot.name = "Precipitation detail and grouped daily forecast"
        precipitationScreenshot.lifetime = .keepAlways
        add(precipitationScreenshot)

        let firstDailyForecast = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "daily-forecast-")
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
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["7-day forecast"].waitForExistence(timeout: 5))

        tabBar.buttons["Places"].tap()
        XCTAssertTrue(app.buttons["Use current location"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["City, town, or ZIP code"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Forecast"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Temperature °C"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Loading National Weather Service data…"].exists)

        app.tabBars.buttons["Radar"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["LIVE NWS RADAR"].exists)
        XCTAssertTrue(app.staticTexts["Precipitation"].exists)
        XCTAssertTrue(app.buttons["Center radar on location"].exists)
        XCTAssertTrue(app.buttons["Refresh radar"].exists)
        XCTAssertTrue(app.buttons["Radar options"].exists)
        XCTAssertFalse(app.sliders["Radar opacity"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["precipitation-intensity-legend"].exists)

        let loading = app.activityIndicators["Checking NWS radar"]
        _ = loading.waitForExistence(timeout: 2)
        XCTAssertTrue(loading.waitForNonExistence(timeout: 30), "The NWS radar service check did not finish")
        XCTAssertFalse(app.staticTexts["Radar connection unavailable"].exists)
        XCTAssertTrue(app.sliders["Radar time"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Latest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play radar"].exists)
        XCTAssertTrue(app.buttons["Previous radar frame"].exists)
        app.buttons["Previous radar frame"].tap()
        XCTAssertTrue(app.buttons["Next radar frame"].isEnabled)

        app.sliders["Radar time"].adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.staticTexts["LIVE NWS RADAR"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OBSERVED"].exists)
        XCTAssertFalse(app.staticTexts["HRRR FORECAST"].exists)

        app.buttons["Radar options"].tap()
        XCTAssertTrue(app.buttons["Adjust radar opacity"].waitForExistence(timeout: 3))
        app.buttons["Adjust radar opacity"].tap()
        XCTAssertTrue(app.sliders["Radar opacity"].waitForExistence(timeout: 3))

        let radarScreenshot = XCTAttachment(screenshot: app.screenshot())
        radarScreenshot.name = "Native NWS radar"
        radarScreenshot.lifetime = .keepAlways
        add(radarScreenshot)
    }

    func testInteractiveMeteogramTimeIndicator() throws {
        let chartHeading = app.staticTexts["24-hour forecast"]
        XCTAssertTrue(chartHeading.waitForExistence(timeout: 35))
        let chart = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        XCTAssertTrue(forecastScrollView.waitForExistence(timeout: 3))
        for _ in 0..<6 where !chart.isHittable {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(chart.isHittable)

        let initialValue = chart.value as? String
        XCTAssertEqual(initialValue, "No time selected")

        let chartYBeforeVerticalDrag = chart.frame.minY
        let verticalDragStart = chart.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)
        )
        let verticalDragEnd = chart.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)
        )
        verticalDragStart.press(forDuration: 0.05, thenDragTo: verticalDragEnd)

        let chartAfterVerticalDrag = app.descendants(matching: .any)
            .matching(identifier: "temperature-precipitation-chart")
            .firstMatch
        XCTAssertLessThan(
            chartAfterVerticalDrag.frame.minY,
            chartYBeforeVerticalDrag - 20,
            "A vertical drag beginning on the chart should scroll the forecast"
        )
        XCTAssertEqual(chartAfterVerticalDrag.value as? String, "No time selected")

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
    }

    func testRadarObservedHistory() throws {
        let radarTab = app.tabBars.buttons["Radar"]
        XCTAssertTrue(radarTab.waitForExistence(timeout: 10))
        radarTab.tap()

        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        let loading = app.activityIndicators["Checking NWS radar"]
        _ = loading.waitForExistence(timeout: 2)
        XCTAssertTrue(loading.waitForNonExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Radar connection unavailable"].exists)

        let timeline = app.sliders["Radar time"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Past 2 hours"].exists)
        XCTAssertTrue(app.staticTexts["Latest"].exists)
        XCTAssertTrue(app.staticTexts["OBSERVED"].exists)
        XCTAssertTrue(app.staticTexts["NOAA · National Weather Service"].exists)
        XCTAssertTrue(app.staticTexts["Precipitation"].exists)
        XCTAssertFalse(app.staticTexts["HRRR FORECAST"].exists)
        XCTAssertFalse(app.staticTexts["+1 hour"].exists)
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

        timeline.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(app.staticTexts["OBSERVED"].waitForExistence(timeout: 5))

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

        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)

        let returnedToTop = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(currentConditions.frame.minY - restingMinY) < 3
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returnedToTop], timeout: 3), .completed)
    }

    func testPlaceSearchSelectsNewForecast() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Places"].tap()

        let search = app.searchFields["City, town, or ZIP code"]
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

    func testReadmeBoulderFahrenheitScreenshots() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        tabBar.buttons["Places"].tap()
        let search = app.searchFields["City, town, or ZIP code"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Boulder, CO")
        let boulder = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Boulder")
        ).firstMatch
        XCTAssertTrue(boulder.waitForExistence(timeout: 20))
        boulder.tap()

        tabBar.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Fahrenheit"].waitForExistence(timeout: 5))
        app.buttons["Fahrenheit"].tap()

        tabBar.buttons["Forecast"].tap()
        XCTAssertTrue(app.staticTexts["Temperature °F"].waitForExistence(timeout: 35))

        let forecastScreenshot = XCTAttachment(screenshot: app.screenshot())
        forecastScreenshot.name = "README Boulder forecast Fahrenheit"
        forecastScreenshot.lifetime = .keepAlways
        add(forecastScreenshot)

        let chartHeading = app.staticTexts["24-hour forecast"]
        let forecastScrollView = app.scrollViews["forecast-scroll-view"]
        XCTAssertTrue(chartHeading.waitForExistence(timeout: 5))
        XCTAssertTrue(forecastScrollView.waitForExistence(timeout: 3))
        let windowFrame = app.windows.firstMatch.frame
        for _ in 0..<6 where chartHeading.frame.minY > windowFrame.minY + 180 {
            forecastScrollView.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(chartHeading.isHittable)

        let chartScreenshot = XCTAttachment(screenshot: app.screenshot())
        chartScreenshot.name = "README Boulder chart Fahrenheit"
        chartScreenshot.lifetime = .keepAlways
        add(chartScreenshot)

        tabBar.buttons["Radar"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 15))
        let loading = app.activityIndicators["Checking NWS radar"]
        _ = loading.waitForExistence(timeout: 2)
        XCTAssertTrue(loading.waitForNonExistence(timeout: 30))
        XCTAssertFalse(app.sliders["Radar opacity"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["precipitation-intensity-legend"].exists)

        let radarScreenshot = XCTAttachment(screenshot: app.screenshot())
        radarScreenshot.name = "README Boulder radar"
        radarScreenshot.lifetime = .keepAlways
        add(radarScreenshot)
    }
}
