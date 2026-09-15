import XCTest

@testable import Awake

final class PMSetStateParserTests: XCTestCase {
  func testReadsSystemWideSleepDisabled() {
    let output = """
      System-wide power settings:
       SleepDisabled\t\t1
      Currently in use:
       standby              1
       sleep                1
      """
    XCTAssertEqual(PMSetStateParser.parseSleepDisabled(from: output), true)
    XCTAssertEqual(
      PMSetStateParser.parseSleepDisabled(
        from: output.replacingOccurrences(of: "SleepDisabled\t\t1", with: "SleepDisabled\t\t0")),
      false)
  }

  func testMissingSleepDisabledOnFreshMacMeansNotDisabled() {
    let output = """
      Currently in use:
       standby              1
       sleep                1
       displaysleep         10
      """
    XCTAssertEqual(PMSetStateParser.parseSleepDisabled(from: output), false)
  }

  func testUnrecognizedOutputIsUnknown() {
    XCTAssertNil(PMSetStateParser.parseSleepDisabled(from: ""))
    XCTAssertNil(PMSetStateParser.parseSleepDisabled(from: "pmset: unexpected failure"))
  }
}
