import XCTest
@testable import RookKit

final class RookReflexTests: XCTestCase {
    func testExactCalculationsStayLocal() throws {
        let intent = try XCTUnwrap(RookReflexCommandParser.parse("What is 15 percent of 240?"))
        guard case .calculation(let calculation) = intent else {
            return XCTFail("Expected a calculation")
        }
        XCTAssertEqual(try XCTUnwrap(calculation.result), 36, accuracy: 0.0001)

        let division = try XCTUnwrap(RookReflexCommandParser.parse("calculate 20 divided by 4"))
        guard case .calculation(let calculation) = division else {
            return XCTFail("Expected a calculation")
        }
        XCTAssertEqual(try XCTUnwrap(calculation.result), 5, accuracy: 0.0001)
    }

    func testExactConversionsStayLocal() throws {
        let distance = try XCTUnwrap(RookReflexCommandParser.parse("convert 5 miles to kilometers"))
        guard case .conversion(let conversion) = distance else {
            return XCTFail("Expected a conversion")
        }
        XCTAssertEqual(try XCTUnwrap(conversion.result), 8.04672, accuracy: 0.0001)

        let temperature = try XCTUnwrap(RookReflexCommandParser.parse("72 fahrenheit to celsius"))
        guard case .conversion(let conversion) = temperature else {
            return XCTFail("Expected a conversion")
        }
        XCTAssertEqual(try XCTUnwrap(conversion.result), 22.2222, accuracy: 0.001)
    }

    func testTimersAndRelativeRemindersResolveWithoutReasoning() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timer = try XCTUnwrap(RookReflexCommandParser.parse("Set a timer for 20 minutes called pasta", now: now))
        guard case .scheduleAlert(let kind, let dueAt, let message) = timer else {
            return XCTFail("Expected a local timer")
        }
        XCTAssertEqual(kind, .timer)
        XCTAssertEqual(dueAt.timeIntervalSince(now), 1_200, accuracy: 0.001)
        XCTAssertEqual(message, "pasta")

        let reminder = try XCTUnwrap(RookReflexCommandParser.parse("Remind me in 2 hours to call Maya", now: now))
        guard case .scheduleAlert(let kind, let dueAt, let message) = reminder else {
            return XCTFail("Expected a local reminder")
        }
        XCTAssertEqual(kind, .reminder)
        XCTAssertEqual(dueAt.timeIntervalSince(now), 7_200, accuracy: 0.001)
        XCTAssertEqual(message, "call maya")
    }

    func testAbsoluteReminderMovesPastTimeToTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2027-01-15T22:00:00Z")!
        let intent = try XCTUnwrap(RookReflexCommandParser.parse(
            "Remind me at 4 pm to stretch",
            now: now,
            calendar: calendar
        ))
        guard case .scheduleAlert(_, let dueAt, _) = intent else {
            return XCTFail("Expected a reminder")
        }
        XCTAssertGreaterThan(dueAt, now)
        XCTAssertTrue(calendar.isDate(dueAt, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
    }

    func testDeviceControlsOnlyMatchBoundedCommands() throws {
        XCTAssertEqual(RookReflexCommandParser.parse("volume up"), .volume(.adjust(0.10)))
        XCTAssertEqual(RookReflexCommandParser.parse("set volume to 55 percent"), .volume(.set(0.55)))
        XCTAssertEqual(RookReflexCommandParser.parse("what's my battery"), .deviceStatus(.battery))
        XCTAssertNil(RookReflexCommandParser.parse("work out the best battery pack for my trip"))
        XCTAssertNil(RookReflexCommandParser.parse("convert my whole spreadsheet from miles to kilometers"))
        XCTAssertNil(RookReflexCommandParser.parse("remind me sometime next week to call Maya"))
    }

    func testWhatsNextReturnsOneCheckpointEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rook-reflex-tests-\(UUID().uuidString)", isDirectory: true)
        var config = RookConfig.recommended
        config.stateDirectory = root.appendingPathComponent("core", isDirectory: true).path
        try config.ensureStateDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = try RookLibrary(config: config)
        let now = ISO8601DateFormatter().date(from: "2027-01-15T17:00:00Z")!
        let checkedAt = ISO8601DateFormatter().string(from: now)
        try library.storeCheckpoint(RookCheckpoint(
            checkedAt: checkedAt,
            timezone: "America/New_York",
            calendarAsOf: checkedAt,
            calendarItems: [
                RookCheckpointEvent(
                    title: "Project review",
                    start: "2027-01-15T17:20:00Z",
                    end: "2027-01-15T18:00:00Z",
                    location: "Zoom"
                ),
                RookCheckpointEvent(
                    title: "Dinner",
                    start: "2027-01-15T23:00:00Z",
                    end: "2027-01-16T00:00:00Z",
                    location: ""
                ),
            ],
            gmailAsOf: checkedAt,
            emailItems: [],
            suggestions: [],
            preparations: []
        ), now: now)

        let decision = try XCTUnwrap(library.cachedOperationalDecision(for: "What's next?", now: now))
        XCTAssertEqual(decision.destination, .instant)
        XCTAssertTrue(decision.response.displayText.contains("Project review"))
        XCTAssertTrue(decision.response.displayText.contains("20 minutes"))
        XCTAssertEqual(decision.response.canvas.first?.items.count, 1)
        XCTAssertEqual(decision.response.canvas.first?.items.first?.label, "Project review")
    }
}
