import Foundation

/// Constants of the hub protocol; the Wattlark hub's docs/hub-protocol.md is the reference.
public enum HubProtocol {
    /// Independent of the stream's schema_version. Bumped only for a change
    /// to the hub's own messages.
    public static let version = 1
    public static let defaultPort = 8765
    public static let bonjourServiceType = "_solis-hub._tcp"
    public static let streamPath = "/v1/stream"
}

/// The supervisor states the hub reports for its solis-poll child.
public enum HubPollerState: Equatable, Sendable {
    case starting
    case running
    case backoff
    case stopping
    case restorationPending
    /// A state a newer hub added; shown, never treated as healthy.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "starting": self = .starting
        case "running": self = .running
        case "backoff": self = .backoff
        case "stopping": self = .stopping
        case "restoration_pending": self = .restorationPending
        default: self = .unknown(rawValue)
        }
    }
}

/// The hub's view of its poller. Times are ISO 8601 strings, or nil.
public struct HubPollerStatus: Decodable, Sendable, Equatable {
    public let state: String
    public let since: String?
    public let restarts: Int
    public let lastExitCode: Int?
    public let nextAttemptAt: String?

    public var kind: HubPollerState { HubPollerState(rawValue: state) }

    public var nextAttemptDate: Date? { nextAttemptAt.flatMap(StreamDecoder.date(from:)) }

    /// Why the feed is not live, or nil while the poller is running. Anything
    /// but running means the hub is reachable and the inverter data is not
    /// being refreshed, which is a different problem from an unreachable hub.
    public func summary(now: Date = Date()) -> String? {
        switch kind {
        case .running:
            return nil
        case .starting:
            return "Hub is up, inverter poller starting"
        case .backoff:
            guard let next = nextAttemptDate else { return "Hub is up, inverter poller restarting" }
            let seconds = max(0, Int(next.timeIntervalSince(now).rounded(.up)))
            return "Hub is up, inverter poller restarting in \(seconds) s"
        case .stopping:
            return "Hub is up, stopping the inverter poller"
        case .restorationPending:
            return "Hub is stopping, inverter limit restoration is still pending"
        case let .unknown(state):
            return "Hub is up, inverter poller is \(state)"
        }
    }
}

/// What the hub says about one of its data sources.
public enum HubSourceState: Equatable, Sendable {
    case ok
    /// Signed in but switched off in the hub's settings (for Hypervolt, also
    /// while voltage control is off).
    case off
    /// Nothing new for longer than the hub allows: an hour for Octopus, 30
    /// minutes for the charger.
    case failing
    case notSignedIn
    /// A state a newer hub added; kept so it can be shown.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "ok": self = .ok
        case "off": self = .off
        case "failing": self = .failing
        case "not_signed_in": self = .notSignedIn
        default: self = .unknown(rawValue)
        }
    }
}

public struct HubSourceStatus: Decodable, Sendable, Equatable {
    /// The raw state, so one this build does not know still decodes.
    public let state: String
    public let detail: String?
    /// ISO 8601, or nil when the source has never worked on this hub run.
    public let lastOk: String?

    public init(state: String, detail: String? = nil, lastOk: String? = nil) {
        self.state = state
        self.detail = detail
        self.lastOk = lastOk
    }

    public var kind: HubSourceState { HubSourceState(rawValue: state) }

    public var lastOkDate: Date? { lastOk.flatMap(StreamDecoder.date(from:)) }
}

/// A source the dashboard should warn about, worded for the person reading it.
public struct HubSourceWarning: Sendable, Equatable, Identifiable {
    /// The hub's name for the source, such as "octopus".
    public let source: String
    public let message: String
    /// The hub's own explanation, when it gave one.
    public let detail: String?

    public var id: String { source }
}

/// The hub's data sources by name. The hub reported none of this until
/// Octopus and Hypervolt sat switched off in its saved settings for a week
/// with nothing on screen to say so; this is what lets a client say so.
public struct HubSources: Decodable, Sendable, Equatable {
    /// Every source the hub reported, including names this build does not know.
    public let all: [String: HubSourceStatus]

    public init(_ all: [String: HubSourceStatus]) {
        self.all = all
    }

    public var octopus: HubSourceStatus? { all["octopus"] }
    public var hypervolt: HubSourceStatus? { all["hypervolt"] }

    private struct Name: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    // Lenient on purpose: this rides on hello, and a source a newer hub
    // describes differently must not cost the client its handshake. An entry
    // that does not decode is left out rather than failing the message.
    public init(from decoder: Decoder) throws {
        var all: [String: HubSourceStatus] = [:]
        if let container = try? decoder.container(keyedBy: Name.self) {
            for key in container.allKeys {
                if let status = try? container.decode(HubSourceStatus.self, forKey: key) {
                    all[Self.snakeCased(key.stringValue)] = status
                }
            }
        }
        self.all = all
    }

    /// The shared decoder's convertFromSnakeCase rewrites dictionary keys as
    /// well as field names, so "heat_pump" arrives as "heatPump". The hub's
    /// names are lower snake_case, which makes this an exact inverse.
    private static func snakeCased(_ key: String) -> String {
        var result = ""
        for character in key {
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Sources that are off or failing, Octopus then Hypervolt then any
    /// others by name. A state this build does not know is not warned
    /// about: it may well be healthy.
    public var warnings: [HubSourceWarning] {
        let known = ["octopus", "hypervolt"]
        let names = known.filter { all[$0] != nil }
            + all.keys.filter { !known.contains($0) }.sorted()
        return names.compactMap { name in
            guard let status = all[name], let message = Self.message(for: name, kind: status.kind) else {
                return nil
            }
            let detail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return HubSourceWarning(
                source: name, message: message, detail: detail?.isEmpty == false ? detail : nil
            )
        }
    }

    private static func message(for name: String, kind: HubSourceState) -> String? {
        switch (name, kind) {
        case ("octopus", .off):
            return "Octopus is switched off in the hub's settings: no prices or charge plan"
        case ("octopus", .failing):
            return "Nothing new from Octopus for over an hour"
        case ("hypervolt", .off):
            return "Hypervolt is switched off in the hub's settings: no car readings"
        case ("hypervolt", .failing):
            return "No car readings from Hypervolt for over 30 minutes"
        case (_, .off):
            return "\(displayName(name)) is switched off in the hub's settings"
        case (_, .failing):
            return "Nothing new from \(displayName(name)) recently"
        default:
            return nil
        }
    }

    private static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

public struct HubHello: Decodable, Sendable, Equatable {
    public let hubProtocolVersion: Int
    public let hubVersion: String
    public let streamSchemaVersion: Int
    public let hubId: String
    /// Where the hub says to reach it away from home; nil when it has no
    /// public address, or is older than this field.
    public let publicUrl: String?
    public let poller: HubPollerStatus?
    /// Nil from a hub older than source reporting.
    public let sources: HubSources?
}

public struct HubSnapshot: Decodable, Sendable {
    /// The merged envelope, or nil before the poller's first sample.
    public let envelope: StreamEnvelope?
    public let poller: HubPollerStatus?
    /// Nil from a hub older than source reporting.
    public let sources: HubSources?
}

private struct HubSourcesBody: Decodable {
    let sources: HubSources?
}

public struct HubErrorMessage: Decodable, Sendable, Equatable {
    public let code: String
    public let message: String
}

public enum HubMessageError: Error, Equatable, Sendable {
    case malformed
    /// The hub forwarded an envelope this build cannot read. Like the
    /// poller's own stream, that means upgrade, not retry.
    case unsupportedStreamSchema(Int)
}

/// Every message the hub sends. Unknown types decode to `.unknown` so a newer
/// hub can add a message without breaking an older client.
public enum HubServerMessage: Sendable {
    case hello(HubHello)
    case snapshot(HubSnapshot)
    case sample(StreamEnvelope)
    case pollerStatus(HubPollerStatus)
    /// Sent whenever one of the hub's sources changes state.
    case sources(HubSources)
    case pong(nonce: String?)
    case error(HubErrorMessage)
    case unknown(type: String)

    private struct Header: Decodable {
        let type: String
    }

    private struct SampleBody: Decodable {
        let envelope: StreamEnvelope
    }

    private struct PongBody: Decodable {
        let nonce: String?

        private enum CodingKeys: String, CodingKey {
            case nonce
        }

        // The hub echoes whatever it was sent; a non-string nonce is not ours.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nonce = try? container.decodeIfPresent(String.self, forKey: .nonce)
        }
    }

    /// Read only to tell a newer schema from a corrupt message when the full
    /// decode has failed.
    private struct SchemaProbe: Decodable {
        struct Inner: Decodable {
            let schemaVersion: Int?
        }

        let envelope: Inner?
    }

    public static func decode(_ text: String) throws -> HubServerMessage {
        try decode(Data(text.utf8))
    }

    public static func decode(_ data: Data) throws -> HubServerMessage {
        let decoder = StreamDecoder.makeJSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw HubMessageError.malformed
        }
        switch header.type {
        case "hello":
            return .hello(try body(HubHello.self, from: data, using: decoder))
        case "snapshot":
            let snapshot = try envelopeBearing(HubSnapshot.self, from: data, using: decoder)
            try requireSupportedSchema(snapshot.envelope)
            return .snapshot(snapshot)
        case "sample":
            let sample = try envelopeBearing(SampleBody.self, from: data, using: decoder)
            try requireSupportedSchema(sample.envelope)
            return .sample(sample.envelope)
        case "poller_status":
            return .pollerStatus(try body(HubPollerStatus.self, from: data, using: decoder))
        case "sources":
            let sources = try body(HubSourcesBody.self, from: data, using: decoder).sources
            return .sources(sources ?? HubSources([:]))
        case "pong":
            return .pong(nonce: try body(PongBody.self, from: data, using: decoder).nonce)
        case "error":
            return .error(try body(HubErrorMessage.self, from: data, using: decoder))
        default:
            return .unknown(type: header.type)
        }
    }

    private static func body<T: Decodable>(
        _ type: T.Type, from data: Data, using decoder: JSONDecoder
    ) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw HubMessageError.malformed
        }
    }

    private static func envelopeBearing<T: Decodable>(
        _ type: T.Type, from data: Data, using decoder: JSONDecoder
    ) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            if let version = (try? decoder.decode(SchemaProbe.self, from: data))?.envelope?.schemaVersion,
               version != StreamDecoder.supportedSchemaVersion {
                throw HubMessageError.unsupportedStreamSchema(version)
            }
            throw HubMessageError.malformed
        }
    }

    private static func requireSupportedSchema(_ envelope: StreamEnvelope?) throws {
        if let envelope, envelope.schemaVersion != StreamDecoder.supportedSchemaVersion {
            throw HubMessageError.unsupportedStreamSchema(envelope.schemaVersion)
        }
    }
}

/// What a client may say to the hub. Deliberately nothing that controls the
/// inverter: attention is a hint about whether anyone is looking.
enum HubClientMessage {
    case attention(Bool)
    case ping(nonce: Int)

    var text: String {
        switch self {
        case let .attention(on):
            return "{\"type\":\"attention\",\"on\":\(on ? "true" : "false")}"
        case let .ping(nonce):
            // The nonce is a counter, so there is nothing to escape.
            return "{\"type\":\"ping\",\"nonce\":\"\(nonce)\"}"
        }
    }
}
