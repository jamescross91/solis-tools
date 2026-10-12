import Foundation
import SolisHubKit
import XCTest

@testable import SolisMenuBar

@MainActor
final class HubAddressTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "solis-address-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The Keychain is never written here, only queried for a service that
    /// does not exist.
    private func model() -> HubSettingsModel {
        HubSettingsModel(defaults: defaults, credentials: HubCredentials(service: suite))
    }

    func testAnHttpsAddressIsTheRemoteOneAndAnythingElseTheLAN() {
        let remote = HubSettingsStore.compose(
            address: "https://pi.tail1.ts.net", lan: "", preferredHubID: "", learnedRemote: ""
        )
        XCTAssertEqual(remote.remoteURL?.absoluteString, "https://pi.tail1.ts.net")
        XCTAssertNil(remote.lanURL)
        let lan = HubSettingsStore.compose(
            address: "192.168.1.20", lan: "", preferredHubID: "", learnedRemote: ""
        )
        XCTAssertEqual(lan.lanURL?.absoluteString, "http://192.168.1.20:8765")
        XCTAssertNil(lan.remoteURL)
    }

    func testOneAddressThenTheHubFillsInTheRest() {
        defaults.set("https://pi.tail1.ts.net", forKey: HubSettingsStore.addressKey)
        XCTAssertNil(HubSettingsStore.connectionSettings(defaults).preferredHubID)
        XCTAssertTrue(HubSettingsStore.learn(hubID: "hub-1", publicURL: "https://pi.tail1.ts.net", defaults))
        let connection = HubSettingsStore.connectionSettings(defaults)
        XCTAssertEqual(connection.preferredHubID, "hub-1")
        XCTAssertEqual(connection.learnedRemoteURL?.absoluteString, "https://pi.tail1.ts.net")
        XCTAssertFalse(HubSettingsStore.learn(hubID: "hub-1", publicURL: "https://pi.tail1.ts.net", defaults))
    }

    func testALanOnlySetupLearnsWhereToGoAway() {
        defaults.set("raspberrypi.local", forKey: HubSettingsStore.addressKey)
        HubSettingsStore.learn(hubID: "hub-1", publicURL: "https://pi.tail1.ts.net", defaults)
        let candidates = HubEndpointSelector.candidates(
            settings: HubSettingsStore.connectionSettings(defaults), discovered: []
        )
        XCTAssertEqual(candidates.map(\.kind), [.lan, .remote])
        XCTAssertEqual(candidates.last?.baseURL.absoluteString, "https://pi.tail1.ts.net")
    }

    func testAPublicAddressThatIsNotHttpsIsNeverLearned() {
        HubSettingsStore.learn(hubID: "hub-1", publicURL: "http://pi.tail1.ts.net", defaults)
        XCTAssertNil(HubSettingsStore.connectionSettings(defaults).learnedRemoteURL)
    }

    func testTheTwoAddressSettingsKeepWorkingAndBecomeOneOnSave() {
        defaults.set("ws://raspberrypi.local:8765", forKey: HubSettingsStore.lanKey)
        defaults.set("https://pi.tail1.ts.net", forKey: HubSettingsStore.remoteKey)
        let before = HubSettingsStore.connectionSettings(defaults)
        XCTAssertEqual(before.lanURL?.host, "raspberrypi.local")
        XCTAssertEqual(before.remoteURL?.host, "pi.tail1.ts.net")

        let form = model()
        XCTAssertEqual(form.addressText, "https://pi.tail1.ts.net")
        XCTAssertEqual(form.lanText, "ws://raspberrypi.local:8765")
        form.token = "token"
        // Saving touches the Keychain item for this test's own service only.
        _ = form.save()
        XCTAssertNil(defaults.string(forKey: HubSettingsStore.remoteKey))
        let after = HubSettingsStore.connectionSettings(defaults)
        XCTAssertEqual(after.lanURL, before.lanURL)
        XCTAssertEqual(after.remoteURL, before.remoteURL)
        try? HubCredentials(service: suite).delete()
    }

    func testALanOnlyLegacySetupBecomesTheAddress() {
        defaults.set("192.168.1.20:8765", forKey: HubSettingsStore.lanKey)
        let form = model()
        XCTAssertEqual(form.addressText, "192.168.1.20:8765")
        XCTAssertEqual(form.lanText, "")
    }

    func testAnAddressThatIsNeitherKindIsFlagged() {
        let form = model()
        form.addressText = "https://"
        XCTAssertNotNil(form.addressProblem)
        form.addressText = "https://pi.tail1.ts.net"
        XCTAssertNil(form.addressProblem)
    }
}
