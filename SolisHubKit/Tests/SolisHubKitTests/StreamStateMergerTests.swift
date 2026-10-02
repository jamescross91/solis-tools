import XCTest

@testable import SolisHubKit

final class StreamStateMergerTests: XCTestCase {
    private func envelope(extra: String = "", polls: Int = 1, control: Bool = true) throws -> StreamEnvelope {
        try Fixtures.decodeEnvelope(
            Fixtures.envelope(
                successfulPolls: polls,
                voltageControl: control ? Fixtures.controlJSON(extra: extra) : "null"
            )
        )
    }

    private let full = ", \"recent_events\": [\(Fixtures.event)]"
        + ", \"configuration\": \(Fixtures.configuration)"
        + ", \"octopus_schedule\": \(Fixtures.schedule)"

    func testLaterSamplesInheritWhatTheFirstOneSent() throws {
        var merger = StreamStateMerger()
        _ = merger.merge(try envelope(extra: full))

        let delta = merger.merge(try envelope(polls: 2))
        let control = try XCTUnwrap(delta.voltageControl)
        XCTAssertEqual(control.recentEvents?.count, 1)
        XCTAssertEqual(control.configuration?.maximumVoltageV, 258.0)
        XCTAssertNotNil(control.octopusSchedule)
    }

    func testAChangedEventListReplacesTheCarriedOne() throws {
        var merger = StreamStateMerger()
        _ = merger.merge(try envelope(extra: full))
        let changed = merger.merge(try envelope(extra: ", \"recent_events\": []"))
        XCTAssertEqual(changed.voltageControl?.recentEvents?.count, 0)
        let after = merger.merge(try envelope())
        XCTAssertEqual(after.voltageControl?.recentEvents?.count, 0)
    }

    /// Before any list has been sent the dashboard still gets an array, as it
    /// did when MonitorStore did this itself.
    func testEventsAreEmptyNotNilBeforeTheFirstList() throws {
        var merger = StreamStateMerger()
        let first = merger.merge(try envelope())
        XCTAssertEqual(first.voltageControl?.recentEvents?.count, 0)
        XCTAssertNil(first.voltageControl?.octopusSchedule)
        XCTAssertNil(first.voltageControl?.configuration)
    }

    func testControlTurnedOffClearsEverythingCarried() throws {
        var merger = StreamStateMerger()
        _ = merger.merge(try envelope(extra: full))
        let off = merger.merge(try envelope(polls: 2, control: false))
        XCTAssertNil(off.voltageControl)
        let back = merger.merge(try envelope(polls: 3))
        XCTAssertEqual(back.voltageControl?.recentEvents?.count, 0)
        XCTAssertNil(back.voltageControl?.configuration)
        XCTAssertNil(back.voltageControl?.octopusSchedule)
    }

    func testResetStartsAFreshRun() throws {
        var merger = StreamStateMerger()
        _ = merger.merge(try envelope(extra: full))
        merger.reset()
        let fresh = merger.merge(try envelope())
        XCTAssertNil(fresh.voltageControl?.configuration)
        XCTAssertNil(fresh.voltageControl?.octopusSchedule)
    }

    func testForgettingTheScheduleKeepsTheRest() throws {
        var merger = StreamStateMerger()
        _ = merger.merge(try envelope(extra: full))
        merger.forgetOctopusSchedule()
        let next = merger.merge(try envelope())
        XCTAssertNil(next.voltageControl?.octopusSchedule)
        XCTAssertEqual(next.voltageControl?.recentEvents?.count, 1)
        XCTAssertNotNil(next.voltageControl?.configuration)
    }

    /// The hub already merged its snapshot, so merging it again changes nothing.
    func testMergingIsIdempotent() throws {
        var first = StreamStateMerger()
        let once = first.merge(try envelope(extra: full))
        var second = StreamStateMerger()
        let twice = second.merge(once)
        XCTAssertEqual(twice.voltageControl?.recentEvents?.count, 1)
        XCTAssertEqual(twice.voltageControl?.configuration, once.voltageControl?.configuration)
    }

    func testFeedStateFollowsTheEvents() throws {
        var feed = HubFeedState()
        let endpoint = HubEndpoint(kind: .lan, baseURL: try XCTUnwrap(URL(string: "http://pi.local:8765")))
        feed.apply(.connected(endpoint))
        XCTAssertTrue(feed.isConnected)
        XCTAssertEqual(feed.endpoint, endpoint)

        feed.apply(.sample(try envelope(extra: full)))
        feed.apply(.sample(try envelope(polls: 2)))
        XCTAssertEqual(feed.envelope?.health.successfulPolls, 2)
        XCTAssertEqual(feed.envelope?.voltageControl?.recentEvents?.count, 1)

        feed.apply(.disconnected(.timedOut))
        XCTAssertFalse(feed.isConnected)
        XCTAssertEqual(feed.lastDisconnect, .timedOut)
        // The last picture stays available while disconnected.
        XCTAssertNotNil(feed.envelope)
    }
}
