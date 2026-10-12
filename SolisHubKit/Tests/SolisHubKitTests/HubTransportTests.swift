import CryptoKit
import Foundation
import XCTest
@testable import SolisHubKit

/// A minimal WebSocket server: it answers the upgrade and then sends one text
/// frame, so a close can land while the handshake is genuinely in flight.
private final class UpgradeServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw XCTSkip("could not open a local listener")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        listener = fd
        port = UInt16(bigEndian: assigned.sin_port)
        Thread.detachNewThread { [self] in accept() }
    }

    deinit { Darwin.close(listener) }

    private func accept() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var request = Data()
        var byte: UInt8 = 0
        while !request.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard read(client, &byte, 1) == 1 else { return }
            request.append(byte)
        }
        let text = String(decoding: request, as: UTF8.self)
        guard let line = text.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("sec-websocket-key:")
        }) else { return }
        let key = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        let digest = Insecure.SHA1.hash(
            data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        )
        let accept = Data(digest).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        let payload = Array("hello".utf8)
        var frame: [UInt8] = [0x81, UInt8(payload.count)]
        frame.append(contentsOf: payload)
        _ = Array(response.utf8).withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
        _ = frame.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
        // Hold the connection open: the client decides when it ends.
        Thread.sleep(forTimeInterval: 5)
    }
}

final class HubTransportTests: XCTestCase {
    /// The address list changing while the first handshake is in flight is
    /// what Bonjour resolving the chosen hub does a few milliseconds after
    /// every launch. The client wedged on it for good, with no error and no
    /// retry, because the aborted receive never returned. Each delay lands the
    /// change at a different point of the handshake; every one must end in a
    /// result.
    func testChangingEndpointsDuringTheHandshakeStillReachesAResult() async throws {
        let server = try UpgradeServer()
        let name = HubEndpoint(kind: .lan, baseURL: URL(string: "http://localhost:\(server.port)")!)
        let address = HubEndpoint(kind: .lan, baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        for delayMicroseconds in [0, 500, 1_000, 2_000, 3_000, 4_000, 6_000, 10_000] {
            let client = HubClient(auth: HubAuth(token: "unused"))
            let outcome = Task { () -> Bool in
                var sawNoEndpoint = false
                for await event in client.events {
                    guard case let .disconnected(reason) = event else { continue }
                    if reason == .noEndpoint {
                        sawNoEndpoint = true
                        continue
                    }
                    return sawNoEndpoint
                }
                return false
            }
            await client.start()
            try await Task.sleep(nanoseconds: 100_000_000)
            await client.updateEndpoints([name])
            try await Task.sleep(nanoseconds: UInt64(delayMicroseconds) * 1_000)
            await client.updateEndpoints([address, name])

            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await outcome.value }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            await client.stop()
            XCTAssertTrue(
                finished,
                "no result six seconds after the endpoints changed \(delayMicroseconds) µs into the handshake"
            )
            if !finished { return }
        }
    }

    /// Whatever URLSession does with a cancelled upgrade, close() itself must
    /// fail a receive that is waiting, so nothing above it can be left hanging.
    func testClosingDuringTheHandshakeNeverLeavesAReceivePending() async throws {
        let server = try UpgradeServer()
        let endpoint = HubEndpoint(
            kind: .lan, baseURL: URL(string: "http://127.0.0.1:\(server.port)")!
        )
        let transport = URLSessionHubTransport()

        for delayMicroseconds in stride(from: 0, through: 12_000, by: 1_000) {
            let socket = try await transport.open(endpoint, headers: [:])
            let receive = Task { () -> Void in
                _ = try? await socket.receive()
            }
            try await Task.sleep(nanoseconds: UInt64(delayMicroseconds) * 1_000)
            socket.close()

            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await receive.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            XCTAssertTrue(
                finished,
                "receive() was still pending 3 s after close() at \(delayMicroseconds) µs"
            )
            if !finished { return }
        }
    }

    func testReceiveAfterCloseFailsImmediately() async throws {
        let server = try UpgradeServer()
        let endpoint = HubEndpoint(
            kind: .lan, baseURL: URL(string: "http://127.0.0.1:\(server.port)")!
        )
        let socket = try await URLSessionHubTransport().open(endpoint, headers: [:])
        socket.close()
        do {
            _ = try await socket.receive()
            XCTFail("receive() on a closed socket returned")
        } catch {
            // Any failure is right; what matters is that it does not suspend.
        }
    }
}
