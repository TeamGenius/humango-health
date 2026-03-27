import Flutter
import HealthKit
import UIKit
import XCTest


@testable import humango_health

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testGetPlatformVersion() {
    let plugin = HumangoHealthPlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String, "iOS " + UIDevice.current.systemVersion)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

}

// MARK: - WorkoutPlanBuilder.convertedDistance Tests

class WorkoutPlanBuilderConvertedDistanceTests: XCTestCase {

  private let builder = WorkoutPlanBuilder()
  private let accuracy = 0.001   // tolerance for floating-point comparisons

  // MARK: Identity – meters → meters

  func testConvertedDistance_metersToMeters_returnsUnchangedValue() {
    let result = builder.convertedDistance(meters: 1000, to: .meters)
    XCTAssertEqual(result.value, 1000, accuracy: accuracy)
    XCTAssertEqual(result.unit, UnitLength.meters)
  }

  func testConvertedDistance_zero_returnsZero() {
    let result = builder.convertedDistance(meters: 0, to: .meters)
    XCTAssertEqual(result.value, 0, accuracy: accuracy)
  }

  // MARK: meters → kilometers

  func testConvertedDistance_1000MetersToKilometers_equals1km() {
    let result = builder.convertedDistance(meters: 1000, to: .kilometers)
    XCTAssertEqual(result.value, 1.0, accuracy: accuracy)
    XCTAssertEqual(result.unit, UnitLength.kilometers)
  }

  func testConvertedDistance_5000MetersToKilometers_equals5km() {
    let result = builder.convertedDistance(meters: 5000, to: .kilometers)
    XCTAssertEqual(result.value, 5.0, accuracy: accuracy)
  }

  func testConvertedDistance_400MetersToKilometers_equals0point4km() {
    let result = builder.convertedDistance(meters: 400, to: .kilometers)
    XCTAssertEqual(result.value, 0.4, accuracy: accuracy)
  }

  // MARK: meters → miles  (1 mile = 1609.344 m)

  func testConvertedDistance_1609point344MetersToMiles_equals1Mile() {
    let result = builder.convertedDistance(meters: 1609.344, to: .miles)
    XCTAssertEqual(result.value, 1.0, accuracy: accuracy)
    XCTAssertEqual(result.unit, UnitLength.miles)
  }

  func testConvertedDistance_5000MetersToMiles_approx3point107miles() {
    let result = builder.convertedDistance(meters: 5000, to: .miles)
    XCTAssertEqual(result.value, 5000 / 1609.344, accuracy: accuracy)
  }

  func testConvertedDistance_halfMarathon_approx13point1miles() {
    // 21_097.5 m ≈ 13.109 miles
    let result = builder.convertedDistance(meters: 21_097.5, to: .miles)
    XCTAssertEqual(result.value, 21_097.5 / 1609.344, accuracy: accuracy)
  }

  // MARK: meters → yards  (1 yard = 0.9144 m)

  func testConvertedDistance_metersToYards_1meter_approx1point094yards() {
    let result = builder.convertedDistance(meters: 1, to: .yards)
    XCTAssertEqual(result.value, 1 / 0.9144, accuracy: accuracy)
    XCTAssertEqual(result.unit, UnitLength.yards)
  }

  func testConvertedDistance_1640point42MetersToYards_approx1793yards() {
    // A common pool distance: 1640.42 m ≈ 1793.63 yards
    let result = builder.convertedDistance(meters: 1640.42, to: .yards)
    XCTAssertEqual(result.value, 1640.42 / 0.9144, accuracy: 0.01)
  }

  func testConvertedDistance_poolLength_25meters_toYards() {
    // 25 m pool → ~27.34 yards
    let result = builder.convertedDistance(meters: 25, to: .yards)
    XCTAssertEqual(result.value, 25 / 0.9144, accuracy: accuracy)
  }

  // MARK: Result unit correctness

  func testConvertedDistance_resultUnitMatchesRequestedUnit_km() {
    let result = builder.convertedDistance(meters: 3000, to: .kilometers)
    XCTAssertEqual(result.unit, UnitLength.kilometers)
  }

  func testConvertedDistance_resultUnitMatchesRequestedUnit_miles() {
    let result = builder.convertedDistance(meters: 3000, to: .miles)
    XCTAssertEqual(result.unit, UnitLength.miles)
  }

  func testConvertedDistance_resultUnitMatchesRequestedUnit_yards() {
    let result = builder.convertedDistance(meters: 3000, to: .yards)
    XCTAssertEqual(result.unit, UnitLength.yards)
  }

  // MARK: Round-trip consistency

  func testConvertedDistance_roundTripKmToMeters_isConsistentWithFoundation() {
    // Convert 5 km (5000 m) → km → back to meters via Foundation Measurement
    let toKm = builder.convertedDistance(meters: 5000, to: .kilometers)
    let backToMeters = toKm.converted(to: .meters)
    XCTAssertEqual(backToMeters.value, 5000, accuracy: accuracy)
  }

  func testConvertedDistance_roundTripMilesToMeters_isConsistentWithFoundation() {
    let toMiles = builder.convertedDistance(meters: 1609.344, to: .miles)
    let backToMeters = toMiles.converted(to: .meters)
    XCTAssertEqual(backToMeters.value, 1609.344, accuracy: accuracy)
  }
}

// MARK: - DateUtils.parseDate Tests

class DateUtilsParseDateTests: XCTestCase {

  // Helper: build a UTC Date for a given year/month/day/hour/minute/second
  private func utcDate(year: Int, month: Int, day: Int,
                       hour: Int, minute: Int, second: Int = 0) -> Date {
    var comps = DateComponents()
    comps.timeZone = TimeZone(secondsFromGMT: 0)
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute; comps.second = second
    return Calendar(identifier: .gregorian).date(from: comps)!
  }

  // MARK: - Happy-path formats

  func testParseDate_iso8601WithFractionalSecondsAndZ_parsesCorrectly() {
    // Format: yyyy-MM-dd'T'HH:mm:ss.SSSZ  (isoFormatter)
    let result = DateUtils.parseDate(from: "2026-03-13T00:30:00.000Z")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30))
  }

  func testParseDate_iso8601WithZ_parsesCorrectly() {
    // Format: yyyy-MM-dd'T'HH:mm:ssZ  (isoFormatterNoFrac)
    let result = DateUtils.parseDate(from: "2026-03-13T00:30:00Z")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30))
  }

  func testParseDate_iso8601WithoutTimezone_parsesAsUTC() {
    // Format: yyyy-MM-dd'T'HH:mm:ss  (customFormatterSec, interpreted as UTC)
    let result = DateUtils.parseDate(from: "2026-03-13T00:30:00")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30))
  }

  func testParseDate_iso8601WithMilliseconds_parsesCorrectly() {
    // Format: yyyy-MM-dd'T'HH:mm:ss.SSS  (customFormatterMs, no timezone)
    let result = DateUtils.parseDate(from: "2026-03-13T00:30:00.123")
    XCTAssertNotNil(result)
    // Should be the same second (milliseconds discarded at second-level comparison is fine;
    // verify the date/time component is correct)
    let expected = utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30, second: 0)
    XCTAssertEqual(result!.timeIntervalSince(expected), 0.123, accuracy: 0.001)
  }

  func testParseDate_iso8601WithMicroseconds_parsesCorrectly() {
    // Format: yyyy-MM-dd'T'HH:mm:ss.SSSSSS  (customFormatterMicro, no timezone)
    let result = DateUtils.parseDate(from: "2026-03-13T00:30:00.123456")
    XCTAssertNotNil(result)
    let expected = utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30, second: 0)
    XCTAssertEqual(result!.timeIntervalSince(expected), 0.123456, accuracy: 0.0001)
  }

  func testParseDate_iso8601WithMillisecondsAndZ_parsesCorrectly() {
    // Z suffix stripped before customFormatterMs is tried
    let result = DateUtils.parseDate(from: "2026-03-13T00:30:00.500Z")
    XCTAssertNotNil(result)
    let expected = utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30, second: 0)
    XCTAssertEqual(result!.timeIntervalSince(expected), 0.5, accuracy: 0.001)
  }

  func testParseDate_iso8601WithPositiveOffset_parsesCorrectly() {
    // e.g. UTC+5:30 → 2026-03-13T06:00:00+05:30 == 2026-03-13T00:30:00Z
    let result = DateUtils.parseDate(from: "2026-03-13T06:00:00+05:30")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30))
  }

  func testParseDate_iso8601WithNegativeOffset_parsesCorrectly() {
    // UTC-5 → 2026-03-13T05:30:00-05:00 doesn't equal 00:30 UTC,
    // but 2026-03-12T19:30:00-05:00 == 2026-03-13T00:30:00Z
    let result = DateUtils.parseDate(from: "2026-03-12T19:30:00-05:00")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2026, month: 3, day: 13, hour: 0, minute: 30))
  }

  func testParseDate_midnight_parsesCorrectly() {
    let result = DateUtils.parseDate(from: "2026-01-01T00:00:00Z")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0))
  }

  func testParseDate_endOfDay_parsesCorrectly() {
    let result = DateUtils.parseDate(from: "2026-12-31T23:59:59Z")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59))
  }

  func testParseDate_leapDay_parsesCorrectly() {
    let result = DateUtils.parseDate(from: "2028-02-29T12:00:00Z")
    XCTAssertNotNil(result)
    XCTAssertEqual(result, utcDate(year: 2028, month: 2, day: 29, hour: 12, minute: 0))
  }

  // MARK: - Invalid / failure cases

  func testParseDate_emptyString_returnsNil() {
    XCTAssertNil(DateUtils.parseDate(from: ""))
  }

  func testParseDate_randomText_returnsNil() {
    XCTAssertNil(DateUtils.parseDate(from: "not-a-date"))
  }

  func testParseDate_dateOnlyNoTime_returnsNil() {
    // "2026-03-13" has no time component — none of the formatters match
    XCTAssertNil(DateUtils.parseDate(from: "2026-03-13"))
  }

  func testParseDate_invalidMonth_returnsNil() {
    XCTAssertNil(DateUtils.parseDate(from: "2026-13-01T00:00:00Z"))
  }

  func testParseDate_invalidDay_returnsNil() {
    XCTAssertNil(DateUtils.parseDate(from: "2026-03-32T00:00:00Z"))
  }

  func testParseDate_invalidNonLeapDay_returnsNil() {
    XCTAssertNil(DateUtils.parseDate(from: "2026-02-29T00:00:00Z"))
  }

  // MARK: - Consistency between equivalent representations

  func testParseDate_withZAndWithoutTimezone_produceSameUTCInstant() {
    let withZ    = DateUtils.parseDate(from: "2026-03-13T00:30:00Z")
    let withoutZ = DateUtils.parseDate(from: "2026-03-13T00:30:00")
    XCTAssertNotNil(withZ)
    XCTAssertNotNil(withoutZ)
    XCTAssertEqual(withZ, withoutZ)
  }

  func testParseDate_fractionalSecondsZAndPlainZ_produceSameSecond() {
    let withFrac    = DateUtils.parseDate(from: "2026-03-13T00:30:00.000Z")
    let withoutFrac = DateUtils.parseDate(from: "2026-03-13T00:30:00Z")
    XCTAssertNotNil(withFrac)
    XCTAssertNotNil(withoutFrac)
    XCTAssertEqual(withFrac, withoutFrac)
  }
}

// MARK: - Shared sleep-test helpers

private let sleepIso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Build a single HKCategorySample with the given HealthKit sleep stage.
private func sleepSample(
    stage: HKCategoryValueSleepAnalysis,
    start: String,
    end: String
) -> HKCategorySample {
    let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    return HKCategorySample(
        type: type,
        value: stage.rawValue,
        start: sleepIso.date(from: start)!,
        end:   sleepIso.date(from: end)!
    )
}

/// The real 16-sample dataset from 2026-03-23, verified by the Python test:
/// Core=194 min, Deep=37 min, REM=160 min → TOTAL_SLEEP = 391 min = 23 460 s.
private func march23Samples() -> [HKCategorySample] {
    return [
        sleepSample(stage: .asleepCore, start: "2026-03-23T19:39:53.109Z", end: "2026-03-23T19:50:23.739Z"),
        sleepSample(stage: .asleepDeep, start: "2026-03-23T19:50:23.739Z", end: "2026-03-23T20:27:25.982Z"),
        sleepSample(stage: .awake,      start: "2026-03-23T20:27:25.982Z", end: "2026-03-23T20:31:26.223Z"),
        sleepSample(stage: .asleepCore, start: "2026-03-23T20:31:26.223Z", end: "2026-03-23T20:59:27.966Z"),
        sleepSample(stage: .asleepREM,  start: "2026-03-23T20:59:27.966Z", end: "2026-03-23T21:00:28.029Z"),
        sleepSample(stage: .asleepCore, start: "2026-03-23T21:00:28.029Z", end: "2026-03-23T21:00:58.060Z"),
        sleepSample(stage: .asleepREM,  start: "2026-03-23T21:00:58.060Z", end: "2026-03-23T21:28:29.764Z"),
        sleepSample(stage: .asleepCore, start: "2026-03-23T21:28:29.764Z", end: "2026-03-23T22:45:04.363Z"),
        sleepSample(stage: .asleepREM,  start: "2026-03-23T22:45:04.363Z", end: "2026-03-23T23:09:35.766Z"),
        sleepSample(stage: .asleepCore, start: "2026-03-23T23:09:35.766Z", end: "2026-03-24T00:01:38.826Z"),
        sleepSample(stage: .asleepREM,  start: "2026-03-24T00:01:38.826Z", end: "2026-03-24T00:34:40.679Z"),
        sleepSample(stage: .asleepCore, start: "2026-03-24T00:34:40.679Z", end: "2026-03-24T01:10:42.651Z"),
        sleepSample(stage: .awake,      start: "2026-03-24T01:10:42.651Z", end: "2026-03-24T01:15:12.896Z"),
        sleepSample(stage: .asleepCore, start: "2026-03-24T01:15:12.896Z", end: "2026-03-24T01:38:44.273Z"),
        sleepSample(stage: .asleepREM,  start: "2026-03-24T01:38:44.273Z", end: "2026-03-24T02:15:46.526Z"),
        sleepSample(stage: .asleepCore, start: "2026-03-24T02:15:46.526Z", end: "2026-03-24T02:17:46.649Z"),
    ]
}

// MARK: - Mock delegate

private class MockSleepDelegate: NSObject, HumangoHealthDataDelegate {
    var callCount = 0
    var lastJson: String?
    var lastSessionId: String?

    func onSleepSessionReady(json: String, sessionId: String) async {
        callCount += 1
        lastJson = json
        lastSessionId = sessionId
    }
}

// MARK: - SleepDataManager.calculateSleepPayload Tests

@available(iOS 14.0, *)
class SleepDataManagerCalculateSleepPayloadTests: XCTestCase {

    private let manager = SleepDataManager.shared

    // MARK: Real dataset — total sleep

    /// Verifies that the integer-seconds rounding algorithm applied to the real
    /// 2026-03-23 watch dataset produces exactly 391 min, matching Apple Health.
    func testCalculateSleepPayload_realDataset_totalSleep391min() {
        let payload = manager.calculateSleepPayload(from: march23Samples())
        XCTAssertNotNil(payload)
        // 391 min × 60 = 23 460 s
        XCTAssertEqual(payload!["TOTAL_SLEEP"] as? Int, 23_460)
    }

    func testCalculateSleepPayload_realDataset_allRequiredKeysPresent() {
        let payload = manager.calculateSleepPayload(from: march23Samples())!
        let required = [
            "SOURCE", "SOURCE_BUNDLE", "TIMEZONE",
            "TOTAL_SLEEP", "SLEEP_IN_BED", "SLEEP_LIGHT", "SLEEP_DEEP",
            "SLEEP_REM", "SLEEP_UNSPECIFIED", "SLEEP_AWAKE",
            "BED_TIME", "WAKE_TIME", "START_DATE", "END_DATE",
        ]
        for key in required {
            XCTAssertNotNil(payload[key], "Missing payload key: \(key)")
        }
    }

    func testCalculateSleepPayload_realDataset_bedTimeIsEarliestSampleStart() {
        let payload = manager.calculateSleepPayload(from: march23Samples())!
        let bedTime = payload["BED_TIME"] as? String
        XCTAssertNotNil(bedTime)
        // The first sample starts at 19:39 on 2026-03-23
        XCTAssertTrue(bedTime!.hasPrefix("2026-03-23T19:"))
    }

    func testCalculateSleepPayload_realDataset_wakeTimeIsLatestSampleEnd() {
        let payload = manager.calculateSleepPayload(from: march23Samples())!
        let wakeTime = payload["WAKE_TIME"] as? String
        XCTAssertNotNil(wakeTime)
        // The last sample ends at 02:17 on 2026-03-24
        XCTAssertTrue(wakeTime!.hasPrefix("2026-03-24T02:"))
    }

    // MARK: Edge cases — nil returns

    func testCalculateSleepPayload_emptySamples_returnsNil() {
        XCTAssertNil(manager.calculateSleepPayload(from: []))
    }

    func testCalculateSleepPayload_singleShortCoreSample_returnsNil() {
        // 30-min core — span < 3 h minimum → discarded → nil
        let s = sleepSample(
            stage: .asleepCore,
            start: "2026-03-24T22:00:00.000Z",
            end:   "2026-03-24T22:30:00.000Z"
        )
        XCTAssertNil(manager.calculateSleepPayload(from: [s]))
    }

    func testCalculateSleepPayload_onlyInBedAndAwake_returnsNil() {
        // 5-h span but Core+Deep+REM = 0 → buildAggregatedPayload returns nil
        let samples = [
            sleepSample(stage: .inBed, start: "2026-03-24T21:00:00.000Z", end: "2026-03-24T22:00:00.000Z"),
            sleepSample(stage: .awake, start: "2026-03-24T22:00:00.000Z", end: "2026-03-25T02:00:00.000Z"),
        ]
        XCTAssertNil(manager.calculateSleepPayload(from: samples))
    }

    // MARK: Group filtering

    func testCalculateSleepPayload_napAndNightSession_onlyNightSessionContributes() {
        // Nap: 30 min Core (below 3 h) — discarded
        // Night: 3 h Core + 3 h Deep = 6 h → valid → TOTAL = 21 600 s (360 min)
        let nap: [HKCategorySample] = [
            sleepSample(stage: .asleepCore,
                        start: "2026-03-24T14:00:00.000Z", end: "2026-03-24T14:30:00.000Z"),
        ]
        let night: [HKCategorySample] = [
            sleepSample(stage: .asleepCore,
                        start: "2026-03-24T22:00:00.000Z", end: "2026-03-25T01:00:00.000Z"),
            sleepSample(stage: .asleepDeep,
                        start: "2026-03-25T01:00:00.000Z", end: "2026-03-25T04:00:00.000Z"),
        ]
        let payload = manager.calculateSleepPayload(from: nap + night)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload!["TOTAL_SLEEP"] as? Int, 21_600)
    }

    func testCalculateSleepPayload_samplesSortOrder_resultIsIndependentOfInputOrder() {
        // Shuffle the known dataset; result must be identical to ordered input.
        let ordered = march23Samples()
        var shuffled = ordered
        shuffled.shuffle()

        let p1 = manager.calculateSleepPayload(from: ordered)!
        let p2 = manager.calculateSleepPayload(from: shuffled)!

        XCTAssertEqual(p1["TOTAL_SLEEP"] as? Int, p2["TOTAL_SLEEP"] as? Int)
        XCTAssertEqual(p1["BED_TIME"]    as? String, p2["BED_TIME"]    as? String)
        XCTAssertEqual(p1["WAKE_TIME"]   as? String, p2["WAKE_TIME"]   as? String)
    }

    func testCalculateSleepPayload_exactlyThreeHourSpan_isIncluded() {
        // Span = exactly 3 h → ≥ minGroupSpan → valid 
        // 3 h Core = 180 min = 10 800 s
        let samples = [
            sleepSample(stage: .asleepCore,
                        start: "2026-03-24T22:00:00.000Z",
                        end:   "2026-03-25T01:00:00.000Z"),
        ]
        let payload = manager.calculateSleepPayload(from: samples)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload!["TOTAL_SLEEP"] as? Int, 10_800)
    }

    func testCalculateSleepPayload_justUnderThreeHourSpan_returnsNil() {
        // 2 h 59 m 59 s < 3 h → discarded
        let samples = [
            sleepSample(stage: .asleepCore,
                        start: "2026-03-24T22:00:00.000Z",
                        end:   "2026-03-25T00:59:59.000Z"),
        ]
        XCTAssertNil(manager.calculateSleepPayload(from: samples))
    }
}

// MARK: - SleepDataManager.deliverPayload + Delegate Tests

@available(iOS 14.0, *)
class SleepDataManagerDeliverPayloadTests: XCTestCase {

    private let manager = SleepDataManager.shared
    private let mockDelegate = MockSleepDelegate()
    private let queryStart = sleepIso.date(from: "2026-03-23T18:00:00.000Z")!
    private let queryEnd   = sleepIso.date(from: "2026-03-24T06:00:00.000Z")!

    override func setUp() {
        super.setUp()
        mockDelegate.callCount = 0
        mockDelegate.lastJson = nil
        mockDelegate.lastSessionId = nil
        HumangoHealthPlugin.delegate = mockDelegate
    }

    override func tearDown() {
        HumangoHealthPlugin.delegate = nil
        super.tearDown()
    }

    // MARK: Delegate invocation

    func testDeliverPayload_validSamples_callsDelegateExactlyOnce() async {
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        XCTAssertEqual(mockDelegate.callCount, 1)
    }

    // MARK: JSON content

    func testDeliverPayload_validSamples_delegateReceivesValidJSON() async {
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        XCTAssertNotNil(mockDelegate.lastJson)
        let data = mockDelegate.lastJson!.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed, "Delegate JSON must be parseable")
    }

    func testDeliverPayload_validSamples_jsonTotalSleepMatches391min() async {
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        let data = mockDelegate.lastJson!.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        // 391 min = 23 460 s
        XCTAssertEqual(parsed["TOTAL_SLEEP"] as? Int, 23_460)
    }

    func testDeliverPayload_validSamples_jsonContainsAllRequiredKeys() async {
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        let data = mockDelegate.lastJson!.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let required = [
            "SOURCE", "SOURCE_BUNDLE", "TIMEZONE",
            "TOTAL_SLEEP", "SLEEP_IN_BED", "SLEEP_LIGHT", "SLEEP_DEEP",
            "SLEEP_REM", "SLEEP_UNSPECIFIED", "SLEEP_AWAKE",
            "BED_TIME", "WAKE_TIME", "START_DATE", "END_DATE",
        ]
        for key in required {
            XCTAssertNotNil(parsed[key], "JSON missing key: \(key)")
        }
    }

    // MARK: sessionId

    func testDeliverPayload_validSamples_sessionIdIsBedTimeAndParseable() async {
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        XCTAssertNotNil(mockDelegate.lastSessionId)
        // sessionId = BED_TIME — must be a valid ISO8601 date string
        XCTAssertNotNil(
            sleepIso.date(from: mockDelegate.lastSessionId!),
            "sessionId must be a parseable ISO8601 date string"
        )
    }

    func testDeliverPayload_validSamples_sessionIdMatchesBedTimeInPayload() async {
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        let data = mockDelegate.lastJson!.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(mockDelegate.lastSessionId, parsed["BED_TIME"] as? String)
    }

    // MARK: Suppression when payload is nil

    func testDeliverPayload_shortSamples_delegateNotCalled() async {
        // 30-min core — calculateSleepPayload returns nil → delegate must not fire
        let short = [
            sleepSample(stage: .asleepCore,
                        start: "2026-03-24T22:00:00.000Z",
                        end:   "2026-03-24T22:30:00.000Z"),
        ]
        await manager.deliverPayload(
            samples: short,
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        XCTAssertEqual(mockDelegate.callCount, 0)
    }

    func testDeliverPayload_emptySamples_delegateNotCalled() async {
        await manager.deliverPayload(samples: [], queryStart: queryStart, queryEnd: queryEnd)
        XCTAssertEqual(mockDelegate.callCount, 0)
    }

    // MARK: Nil delegate safety

    func testDeliverPayload_nilDelegate_doesNotCrash() async {
        HumangoHealthPlugin.delegate = nil
        // Must not crash — only emits a debugPrint warning
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
    }

    func testDeliverPayload_nilDelegate_callCountStillZero() async {
        HumangoHealthPlugin.delegate = nil
        await manager.deliverPayload(
            samples: march23Samples(),
            queryStart: queryStart,
            queryEnd: queryEnd
        )
        XCTAssertEqual(mockDelegate.callCount, 0)
    }
}

