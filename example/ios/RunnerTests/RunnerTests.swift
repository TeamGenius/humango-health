import Flutter
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

