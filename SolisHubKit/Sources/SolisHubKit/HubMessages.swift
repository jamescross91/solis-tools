import Foundation

/// Constants of the hub protocol; docs/hub-protocol.md is the reference.
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

public struct HubHello: Decodable, Sendable, Equatable {
    public let hubProtocolVersion: Int
    public let hubVersion: String
    public let streamSchemaVersion: Int
    public let hubId: String
    public let poller: HubPollerStatus?
}

public struct HubSnapshot: Decodable, Sendable {
    /// The merged envelope, or nil before the poller's first sample.
    public let envelope: StreamEnvelope?
    public let poller: HubPollerStatus?
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
