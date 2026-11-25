// Linked into the app by build.sh. Multiplayer between phones in the same room over Wi-Fi Aware (iOS 26+): no
// router, no shared Wi-Fi network, no IP address to type.
//
// The game plays over UDP (ENet on 33771, plus the port's names and heartbeat on 33772, src/native/Port/PortNames.cs)
// and stays unchanged. Wi-Fi Aware carries those datagrams between the phones:
//  - Hosting phone: publishes the service while hosting. Each paired phone that connects gets its own two UDP sockets
//    to 127.0.0.1:33771 and :33772, so the game's host sees it as one more player on this phone.
//  - Joining phone: lists the paired phones that are hosting; joining one opens a Wi-Fi Aware connection to it and
//    UDP listeners on 127.0.0.1:33771 and :33772, and the game joins 127.0.0.1 as if the host were on this phone.
// One Wi-Fi Aware (TCP) connection per joining phone carries both ports: frames of [port index][length (2 bytes)]
// [datagram]. Phones must be paired once per pair through Apple's pairing screens (port_nearby_pair).
//
// Dropped links: the joining phone starts every connection with a hello frame carrying a token for this join, and
// both phones send a keepalive frame every second. When the link fails, or goes quiet for a few seconds after
// keepalives were heard, the joining phone dials the host again (the same endpoint, then a fresh search for that
// phone) and says hello with the same token, and the host gives the new connection the same UDP sockets. The game's
// UDP addresses never change, so ENet only sees a few seconds of lost packets and resends them (both phones wait
// 20 s before dropping a player: ENetHost.DoClientHandshake, PortMultiplayer.ExtendNearbyTimeout). Older builds
// ignore these frames and work as before, without reconnecting.
//
// C entry points (src/native/Port/PortNearby.cs), called on the main thread.
import DeviceDiscoveryUI
import Foundation
import Network
import SwiftUI
import UIKit
import WiFiAware

private let serviceName = "_sts2port._tcp" // Info.plist WiFiAwareServices (build.sh)
private let gamePorts: [UInt16] = [33771, 33772]
private let helloFrame = 0xFF // joining phone -> host, first frame of every connection: the join's token (8 bytes)
private let keepaliveFrame = 0xFE // both ways, every second
private let joinQuietLimit: Duration = .seconds(4) // joining phone: dial again after this long without a frame
private let hostQuietLimit: Duration = .seconds(10) // host: close a connection this quiet (the joiner redials)
private let redialFor: Duration = .seconds(25) // the game gives up on the host after 20 s
private let redialGrace: Duration = .seconds(30) // host: keeps a joining phone's game sockets this long for a redial

// MARK: C entry points

private var returned: UnsafeMutablePointer<CChar>?

/// Returns a C string that stays valid until the next call (main thread only).
private func cString(_ s: String) -> UnsafePointer<CChar> {
	free(returned)
	returned = strdup(s)
	return UnsafePointer(returned!)
}

@_cdecl("port_nearby_supported")
public func port_nearby_supported() -> Int32 {
	if #available(iOS 26.0, *) { return Nearby.supported ? 1 : 0 }
	return 0
}

@_cdecl("port_nearby_status")
public func port_nearby_status() -> UnsafePointer<CChar> {
	if #available(iOS 26.0, *) { return cString(MainActor.assumeIsolated { Nearby.shared.status }) }
	return cString("unavailable (needs iOS 26)")
}

/// Starts or stops offering this phone's hosted game to paired phones nearby.
@_cdecl("port_nearby_host")
public func port_nearby_host(_ on: Int32) {
	if #available(iOS 26.0, *) { MainActor.assumeIsolated { Nearby.shared.setHosting(on != 0) } }
}

/// Starts or stops looking for paired phones that are hosting.
@_cdecl("port_nearby_browse")
public func port_nearby_browse(_ on: Int32) {
	if #available(iOS 26.0, *) { MainActor.assumeIsolated { Nearby.shared.setBrowsing(on != 0) } }
}

/// JSON array of the hosting phones found: [{"id": "<device id>", "name": "..."}].
@_cdecl("port_nearby_hosts")
public func port_nearby_hosts() -> UnsafePointer<CChar> {
	if #available(iOS 26.0, *) { return cString(MainActor.assumeIsolated { Nearby.shared.hostsJSON }) }
	return cString("[]")
}

/// Connects to a hosting phone and starts the local relay. Poll port_nearby_join_state for the result.
@_cdecl("port_nearby_join")
public func port_nearby_join(_ device: UInt64) {
	if #available(iOS 26.0, *) { MainActor.assumeIsolated { Nearby.shared.join(device) } }
}

/// 0 not joined, 1 connecting, 2 ready (the game can join 127.0.0.1), 3 failed or disconnected.
@_cdecl("port_nearby_join_state")
public func port_nearby_join_state() -> Int32 {
	if #available(iOS 26.0, *) { return MainActor.assumeIsolated { Nearby.shared.joinState } }
	return 0
}

@_cdecl("port_nearby_leave")
public func port_nearby_leave() {
	if #available(iOS 26.0, *) { MainActor.assumeIsolated { Nearby.shared.leave() } }
}

/// Number of phones paired with this one (-1 before it's known).
@_cdecl("port_nearby_paired_count")
public func port_nearby_paired_count() -> Int32 {
	if #available(iOS 26.0, *) { return MainActor.assumeIsolated { Nearby.shared.pairedCount } }
	return 0
}

/// Relay events since the last call (drops, reconnects), one per line; "" if none.
@_cdecl("port_nearby_events")
public func port_nearby_events() -> UnsafePointer<CChar> {
	let list = relayEvents.modify { events -> [String] in
		defer { events.removeAll() }
		return events
	}
	return cString(list.joined(separator: "\n"))
}

/// Shows Apple's pairing screens (make this phone visible / find the other phone).
@_cdecl("port_nearby_pair")
public func port_nearby_pair() {
	if #available(iOS 26.0, *) { MainActor.assumeIsolated { Nearby.shared.showPairing() } }
}

// MARK: shared state

/// A value used from several threads.
private final class Locked<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: Value

	init(_ value: Value) { stored = value }

	var value: Value {
		lock.lock()
		defer { lock.unlock() }
		return stored
	}

	func set(_ value: Value) {
		lock.lock()
		stored = value
		lock.unlock()
	}

	@discardableResult
	func modify<Result>(_ body: (inout Value) -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body(&stored)
	}
}

/// Relay events for the game's log (port_nearby_events).
private let relayEvents = Locked<[String]>([])

private func note(_ event: String) {
	relayEvents.modify { if $0.count < 100 { $0.append(event) } }
}

private func elapsed(since start: ContinuousClock.Instant) -> String {
	let d = (ContinuousClock.now - start).components
	return String(format: "%.1f s", Double(d.seconds) + Double(d.attoseconds) / 1e18)
}

/// A short name for a joining phone in the log.
private func short(_ token: UInt64) -> String { String(String(token, radix: 16).prefix(4)) }

// MARK: frames

/// One datagram for one of the game's ports (or a hello / keepalive), as sent over a Wi-Fi Aware connection.
private func frame(_ port: Int, _ payload: Data) -> Data {
	var d = Data(capacity: payload.count + 3)
	d.append(UInt8(port))
	d.append(UInt8(payload.count >> 8))
	d.append(UInt8(payload.count & 0xFF))
	d.append(payload)
	return d
}

@available(iOS 26.0, *)
private typealias Link = NetworkConnection<TCP>

/// Sends frames on a Wi-Fi Aware connection in order, from any thread.
@available(iOS 26.0, *)
private final class Outbox: @unchecked Sendable {
	private let continuation: AsyncStream<Data>.Continuation
	private let task: Task<Void, Never>

	init(_ link: Link, onError: @escaping @Sendable (Error) -> Void) {
		var c: AsyncStream<Data>.Continuation!
		let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(512)) { c = $0 }
		continuation = c
		task = Task {
			for await data in stream {
				do { try await link.send(data) } catch {
					onError(error)
					return
				}
			}
		}
	}

	func send(_ port: Int, _ payload: Data) { continuation.yield(frame(port, payload)) }

	func close() {
		continuation.finish()
		task.cancel()
	}
}

/// Reads frames from a Wi-Fi Aware connection until it closes.
@available(iOS 26.0, *)
private func readFrames(_ link: Link, _ deliver: (Int, Data) -> Void) async throws {
	while true {
		let (head, _) = try await link.receive(exactly: 3)
		if head.count < 3 { return } // closed
		let port = Int(head[head.startIndex])
		let length = Int(head[head.startIndex + 1]) << 8 | Int(head[head.startIndex + 2])
		let (body, _) = length > 0 ? try await link.receive(exactly: length) : (Data(), nil)
		if body.count < length { return }
		deliver(port, body)
	}
}

/// Receives datagrams on a UDP connection until it's cancelled.
private func receiveLoop(_ udp: NWConnection, _ deliver: @escaping (Data) -> Void) {
	udp.receiveMessage { data, _, _, error in
		if let data, !data.isEmpty { deliver(data) }
		if error == nil, udp.state != .cancelled { receiveLoop(udp, deliver) }
	}
}

private let relayQueue = DispatchQueue(label: "port.nearby.relay", qos: .userInteractive)

/// One Wi-Fi Aware connection: sends frames in order, reads them, sends a keepalive every second, and ends (once,
/// reporting why) when it fails, the other phone closes it, or it goes quiet after the other phone's keepalives were
/// heard (a phone without keepalives is never cut off for being quiet). armed: the other phone is known to send
/// keepalives, so it must be heard from within the quiet limit from the start.
@available(iOS 26.0, *)
private final class Wire: @unchecked Sendable {
	let link: Link
	private let quietLimit: Duration
	private let ended = Locked(false)
	private let lastHeard: Locked<ContinuousClock.Instant?> // nil until the other phone sends a keepalive
	private let heard = Locked(false)
	private let heardKeepalive = Locked(false)
	private var outbox: Outbox?
	private var tasks: [Task<Void, Never>] = []

	init(_ link: Link, quietLimit: Duration, armed: Bool = false) {
		self.link = link
		self.quietLimit = quietLimit
		lastHeard = Locked(armed ? .now : nil)
	}

	var isEnded: Bool { ended.value }
	var hasHeard: Bool { heard.value }
	var sendsKeepalives: Bool { heardKeepalive.value }

	func send(_ port: Int, _ payload: Data) { outbox?.send(port, payload) }

	/// deliver: every frame but keepalives, on a reader task. onEnd: called at most once.
	func start(deliver: @escaping @Sendable (Int, Data) -> Void, onEnd: @escaping @Sendable (String) -> Void) {
		outbox = Outbox(link) { [weak self] error in self?.end("couldn't send (\(error))", onEnd) }
		let link = self.link
		tasks.append(Task { [weak self] in
			var why = "closed by the other phone"
			do {
				try await readFrames(link) { port, data in
					guard let self else { return }
					self.heard.set(true)
					if port == keepaliveFrame { self.heardKeepalive.set(true) }
					if port == keepaliveFrame || self.lastHeard.value != nil { self.lastHeard.set(.now) }
					if port != keepaliveFrame { deliver(port, data) }
				}
			} catch {
				why = "couldn't receive (\(error))"
			}
			self?.end(why, onEnd)
		})
		tasks.append(Task { [weak self] in
			while !Task.isCancelled { // the first keepalive goes out at once: a redialing phone waits for it
				guard let self, !self.isEnded else { return }
				self.outbox?.send(keepaliveFrame, Data())
				if let heard = self.lastHeard.value, ContinuousClock.now - heard > self.quietLimit {
					self.end("nothing received for \(elapsed(since: heard))", onEnd)
					return
				}
				try? await Task.sleep(for: .seconds(1))
			}
		})
	}

	private func end(_ why: String, _ onEnd: (String) -> Void) {
		let first = ended.modify { e -> Bool in
			defer { e = true }
			return !e
		}
		guard first else { return }
		close()
		onEnd(why)
	}

	/// Stops without reporting (its owner is done with it).
	func close() {
		ended.set(true)
		tasks.forEach { $0.cancel() }
		outbox?.close()
	}
}

// MARK: host side

/// A joining phone, on the host: its two UDP sockets to the game on this phone, and its current connection.
@available(iOS 26.0, *)
private final class HostSession: @unchecked Sendable {
	let token: UInt64? // nil: a build without hello frames (one connection, no redial)
	let wire = Locked<Wire?>(nil)
	var expiry: Task<Void, Never>? // guarded by HostRelay's lock
	private var udp: [NWConnection] = []

	init(token: UInt64?) {
		self.token = token
		for (i, port) in gamePorts.enumerated() {
			let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
			conn.start(queue: relayQueue)
			receiveLoop(conn) { [weak self] data in self?.wire.value?.send(i, data) }
			udp.append(conn)
		}
	}

	/// A datagram from the joining phone for the game.
	func deliver(_ port: Int, _ data: Data) {
		if port < udp.count { udp[port].send(content: data, completion: .idempotent) }
	}

	func close() {
		expiry?.cancel()
		wire.value?.close()
		wire.set(nil)
		udp.forEach { $0.cancel() }
	}
}

/// The host's side of nearby play: gives each incoming connection the game sockets of the phone its hello names.
@available(iOS 26.0, *)
private final class HostRelay: @unchecked Sendable {
	private let lock = NSLock()
	private var sessions: [UInt64: HostSession] = [:]
	private var legacy: [ObjectIdentifier: HostSession] = [:]
	private var stopped = false
	private var redialCount = 0

	var connected: Int {
		lock.lock()
		defer { lock.unlock() }
		return sessions.values.filter { $0.wire.value != nil }.count + legacy.count
	}

	var redials: Int {
		lock.lock()
		defer { lock.unlock() }
		return redialCount
	}

	func adopt(_ link: Link) {
		let wire = Wire(link, quietLimit: hostQuietLimit)
		let session = Locked<HostSession?>(nil)
		wire.start(deliver: { [weak self] port, data in
			if let s = session.value {
				if port != helloFrame { s.deliver(port, data) }
				return
			}
			// The first frame says which phone this is.
			guard let self else { return }
			if port == helloFrame, data.count == 8 {
				let token = UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
				session.set(self.attach(wire, token: token))
			} else {
				let s = self.attachLegacy(wire)
				session.set(s)
				s?.deliver(port, data)
			}
		}, onEnd: { [weak self] why in self?.detach(wire, session.value, why) })
	}

	private func attach(_ wire: Wire, token: UInt64) -> HostSession? {
		lock.lock()
		defer { lock.unlock() }
		guard !stopped else {
			wire.close()
			return nil
		}
		let s: HostSession
		if let existing = sessions[token] {
			s = existing
			redialCount += 1
			note("phone \(short(token)) reconnected")
		} else {
			s = HostSession(token: token)
			sessions[token] = s
			note("phone \(short(token)) connected")
		}
		s.expiry?.cancel()
		s.expiry = nil
		let old = s.wire.value
		s.wire.set(wire)
		if old !== wire { old?.close() }
		return s
	}

	private func attachLegacy(_ wire: Wire) -> HostSession? {
		lock.lock()
		defer { lock.unlock() }
		guard !stopped else {
			wire.close()
			return nil
		}
		let s = HostSession(token: nil)
		s.wire.set(wire)
		legacy[ObjectIdentifier(wire)] = s
		note("a phone with an older build connected (it can't reconnect after a drop)")
		return s
	}

	private func detach(_ wire: Wire, _ session: HostSession?, _ why: String) {
		lock.lock()
		defer { lock.unlock() }
		guard let s = session, s.wire.value === wire else { return }
		s.wire.set(nil)
		guard let token = s.token else {
			legacy[ObjectIdentifier(wire)] = nil
			s.close()
			note("a phone with an older build disconnected: \(why)")
			return
		}
		note("link to phone \(short(token)) dropped: \(why); waiting for it to reconnect")
		s.expiry = Task { [weak self] in
			try? await Task.sleep(for: redialGrace)
			if !Task.isCancelled { self?.expire(token, s) }
		}
	}

	private func expire(_ token: UInt64, _ s: HostSession) {
		lock.lock()
		defer { lock.unlock() }
		guard sessions[token] === s, s.wire.value == nil else { return }
		sessions[token] = nil
		s.close()
		note("phone \(short(token)) didn't reconnect")
	}

	func stop() {
		lock.lock()
		defer { lock.unlock() }
		stopped = true
		for s in Array(sessions.values) + Array(legacy.values) { s.close() }
		sessions.removeAll()
		legacy.removeAll()
	}
}

// MARK: join side

/// This phone's side of a nearby game: the UDP listeners the game joins on 127.0.0.1, and the current connection
/// to the host, replaced when it drops.
@available(iOS 26.0, *)
private final class JoinRelay: @unchecked Sendable {
	let device: UInt64
	var endpoint: WAEndpoint // main actor
	let token = UInt64.random(in: 1...UInt64.max)
	let wire = Locked<Wire?>(nil)
	let closed = Locked(false)
	let hostSendsKeepalives = Locked(false) // a build that can take a redial
	private let game = Locked<[NWConnection?]>([nil, nil]) // the game's own socket for each port (the latest one)
	private var listeners: [NWListener] = []

	init(device: UInt64, endpoint: WAEndpoint) {
		self.device = device
		self.endpoint = endpoint
	}

	var hello: Data { withUnsafeBytes(of: token.littleEndian) { Data($0) } }

	/// Listens on 127.0.0.1 for the game; throws if a port is taken (e.g. this phone is hosting).
	func listen() throws {
		for (i, port) in gamePorts.enumerated() {
			let params = NWParameters.udp
			params.allowLocalEndpointReuse = true
			params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
			let listener = try NWListener(using: params)
			listener.newConnectionHandler = { [weak self] conn in
				conn.start(queue: relayQueue)
				self?.game.modify { $0[i] = conn }
				receiveLoop(conn) { data in self?.wire.value?.send(i, data) }
			}
			listener.start(queue: relayQueue)
			listeners.append(listener)
		}
	}

	/// A datagram from the host for the game.
	func deliver(_ port: Int, _ data: Data) {
		if port < gamePorts.count { game.value[port]?.send(content: data, completion: .idempotent) }
	}

	func close() {
		closed.set(true)
		wire.value?.close()
		wire.set(nil)
		listeners.forEach { $0.cancel() }
		game.value.forEach { $0?.cancel() }
	}
}

// MARK: state

@available(iOS 26.0, *)
@MainActor
final class Nearby {
	static let shared = Nearby()
	nonisolated static var supported: Bool {
		WACapabilities.supportedFeatures.contains(.wifiAware)
			&& WAPublishableService.allServices[serviceName] != nil && WASubscribableService.allServices[serviceName] != nil
	}

	private var hosting = false
	private var browsing = false
	private var pairingShown = false
	private var listenerTask: Task<Void, Never>?
	private var browserTask: Task<Void, Never>?
	private var pairedTask: Task<Void, Never>?
	private var hostRelay: HostRelay?
	private var endpoints: [WAEndpoint] = []
	private var joinRelay: JoinRelay?
	private var redialTask: Task<Void, Never>?
	private var joinRedials = 0
	private(set) var joinState: Int32 = 0
	private(set) var pairedCount: Int32 = -1
	private var listenerState = "off"
	private var browserState = "off"
	private var lastError = ""

	private init() {
		pairedTask = Task { [weak self] in
			do {
				for try await devices in WAPairedDevice.allDevices { self?.pairedCount = Int32(devices.count) }
			} catch {
				self?.lastError = "paired devices: \(error)"
			}
		}
	}

	var status: String {
		guard Nearby.supported else { return "not supported on this device" }
		let paired = pairedCount < 0 ? "?" : "\(pairedCount)"
		var parts = ["\(paired) paired"]
		if hosting {
			parts.append("hosting (\(listenerState), \(hostRelay?.connected ?? 0) connected, \(hostRelay?.redials ?? 0) reconnects)")
		}
		if browsing { parts.append("looking (\(browserState), \(endpoints.count) hosting)") }
		if joinRelay != nil || joinState != 0 {
			var joined = "joined: \(["no", "connecting", "ready", "failed"][Int(joinState)])"
			if redialTask != nil { joined += ", reconnecting" }
			if joinRedials > 0 { joined += ", \(joinRedials) reconnects" }
			parts.append(joined)
		}
		if !lastError.isEmpty { parts.append("last error: \(lastError)") }
		return parts.joined(separator: "; ")
	}

	var hostsJSON: String {
		let list = endpoints.map { ep -> [String: String] in
			let d = ep.device
			let name = d.name ?? d.pairingInfo?.pairingName ?? d.pairingInfo?.modelName ?? "Nearby phone"
			return ["id": String(d.id), "name": name]
		}
		guard let data = try? JSONSerialization.data(withJSONObject: list) else { return "[]" }
		return String(decoding: data, as: UTF8.self)
	}

	// MARK: hosting

	func setHosting(_ on: Bool) {
		guard on != hosting, Nearby.supported else { return }
		hosting = on
		if on {
			hostRelay = HostRelay()
			startListener()
		} else {
			listenerTask?.cancel()
			listenerTask = nil
			listenerState = "off"
			hostRelay?.stop()
			hostRelay = nil
		}
	}

	/// Publishes until hosting stops. Publishing ends by itself after 2 minutes (connections stay up): start again.
	private func startListener() {
		guard listenerTask == nil, hosting, !pairingShown, let service = WAPublishableService.allServices[serviceName] else { return }
		listenerTask = Task { [weak self] in
			while let self, self.hosting, !Task.isCancelled, let relay = self.hostRelay {
				do {
					let listener = try NetworkListener(
						for: .wifiAware(.connecting(to: service, from: .allPairedDevices, datapath: .realtime)),
						using: .parameters { TCP() }.wifiAware { $0.performanceMode = .realtime })
						.onStateUpdate { _, state in Task { @MainActor in self.listenerState = "\(state)" } }
					try await listener.run { link in relay.adopt(link) }
				} catch {
					if Task.isCancelled { break }
					self.lastError = "publishing: \(error)"
				}
				try? await Task.sleep(for: .seconds(1))
			}
		}
	}

	// MARK: joining

	func setBrowsing(_ on: Bool) {
		guard on != browsing, Nearby.supported else { return }
		browsing = on
		if on {
			startBrowser()
		} else {
			browserTask?.cancel()
			browserTask = nil
			browserState = "off"
			endpoints = []
		}
	}

	private func startBrowser() {
		guard browserTask == nil, browsing, !pairingShown, let service = WASubscribableService.allServices[serviceName] else { return }
		browserTask = Task { [weak self] in
			while let self, self.browsing, !Task.isCancelled {
				do {
					let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
						.onStateUpdate { _, state in Task { @MainActor in self.browserState = "\(state)" } }
					try await browser.run { found in Task { @MainActor in self.endpoints = found } }
				} catch {
					if Task.isCancelled { break }
					self.lastError = "looking: \(error)"
				}
				self.endpoints = []
				try? await Task.sleep(for: .seconds(1))
			}
		}
	}

	func join(_ device: UInt64) {
		leave()
		guard let ep = endpoints.first(where: { $0.device.id == device }) else {
			lastError = "that phone isn't hosting anymore"
			joinState = 3
			return
		}
		joinState = 1
		joinRedials = 0
		let relay = JoinRelay(device: device, endpoint: ep)
		joinRelay = relay
		do {
			try relay.listen()
		} catch {
			lastError = "local relay: \(error)"
			failJoin(relay)
			return
		}
		Task { [weak self] in
			guard let self else { return }
			if await self.dial(relay, ep, within: .seconds(15)) {
				if self.joinRelay === relay { self.joinState = 2 }
			} else {
				self.failJoin(relay)
			}
		}
	}

	/// Opens a connection to the host for this join and makes it the relay's. False if it isn't ready in time, or (when
	/// the host is known to send keepalives) if the host isn't heard from: a connection alone doesn't prove the host's
	/// game is still there.
	private func dial(_ relay: JoinRelay, _ ep: WAEndpoint, within limit: Duration) async -> Bool {
		let mustHear = relay.hostSendsKeepalives.value
		let state = Locked(0) // 1 ready, 2 failed
		let failure = Locked("")
		let link = NetworkConnection(to: ep, using: .parameters { TCP() }.wifiAware { $0.performanceMode = .realtime })
			.onStateUpdate { _, s in
				switch s {
				case .ready:
					state.set(1)
				case .failed(let error):
					failure.set("\(error)")
					state.set(2)
				case .cancelled:
					state.set(2)
				default:
					break
				}
			}
		let wire = Wire(link, quietLimit: joinQuietLimit, armed: mustHear)
		wire.start(deliver: { port, data in relay.deliver(port, data) },
		           onEnd: { [weak self] why in Task { @MainActor in self?.linkEnded(relay, wire, why) } })
		wire.send(helloFrame, relay.hello) // first, so the host knows which phone this is
		let deadline = ContinuousClock.now + limit
		func answered() -> Bool { state.value == 1 && (!mustHear || wire.hasHeard) }
		while !answered(), state.value != 2, !wire.isEnded, !relay.closed.value, ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(50))
		}
		guard answered(), !wire.isEnded, !relay.closed.value, joinRelay === relay else {
			wire.close()
			if !failure.value.isEmpty { lastError = "connection: \(failure.value)" }
			return false
		}
		relay.wire.set(wire)
		return true
	}

	private func linkEnded(_ relay: JoinRelay, _ wire: Wire, _ why: String) {
		guard joinRelay === relay, !relay.closed.value, relay.wire.value === wire else { return }
		relay.wire.set(nil)
		if wire.sendsKeepalives { relay.hostSendsKeepalives.set(true) }
		lastError = "link: \(why)"
		note("link to the host dropped: \(why); reconnecting")
		redial(relay)
	}

	/// Dials the host again until it answers or the game would have given up: first the endpoint we had, then
	/// wherever a fresh search finds that phone.
	private func redial(_ relay: JoinRelay) {
		guard redialTask == nil else { return }
		let started = ContinuousClock.now
		redialTask = Task { [weak self] in
			var attempt = 0
			while let self, self.joinRelay === relay, !relay.closed.value, ContinuousClock.now - started < redialFor {
				attempt += 1
				if attempt > 1, let found = await self.find(relay.device, within: .seconds(4)) { relay.endpoint = found }
				guard self.joinRelay === relay, !relay.closed.value else { break }
				if await self.dial(relay, relay.endpoint, within: .seconds(5)) {
					self.joinRedials += 1
					self.redialTask = nil
					note("reconnected to the host after \(elapsed(since: started)) (attempt \(attempt))")
					return
				}
				try? await Task.sleep(for: .milliseconds(300))
			}
			guard let self else { return }
			self.redialTask = nil
			if self.joinRelay === relay, !relay.closed.value {
				note("gave up reconnecting after \(elapsed(since: started))")
				self.failJoin(relay)
			}
		}
	}

	/// Looks for a paired phone hosting the game, for up to `limit`.
	private func find(_ device: UInt64, within limit: Duration) async -> WAEndpoint? {
		guard let service = WASubscribableService.allServices[serviceName] else { return nil }
		let search = Task { () -> WAEndpoint? in
			let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
			return try? await browser.run { found in
				if let ep = found.first(where: { $0.device.id == device }) { return .finish(ep) }
				return .continue
			}
		}
		let timer = Task {
			try? await Task.sleep(for: limit)
			search.cancel()
		}
		let ep = await search.value
		timer.cancel()
		return ep
	}

	private func failJoin(_ relay: JoinRelay) {
		relay.close()
		if joinRelay === relay {
			redialTask?.cancel()
			redialTask = nil
			joinRelay = nil
			joinState = 3
		}
	}

	func leave() {
		redialTask?.cancel()
		redialTask = nil
		joinRelay?.close()
		joinRelay = nil
		joinState = 0
	}

	// MARK: pairing

	func showPairing() {
		guard Nearby.supported, !pairingShown,
		      let pub = WAPublishableService.allServices[serviceName],
		      let sub = WASubscribableService.allServices[serviceName],
		      let presenter = Nearby.topViewController() else { return }
		// Publishing or looking while Apple's pairing screens are up gets in their way.
		pairingShown = true
		listenerTask?.cancel()
		listenerTask = nil
		browserTask?.cancel()
		browserTask = nil
		let host = UIHostingController(rootView: PairingView(publish: pub, subscribe: sub) { [weak self] in
			presenter.dismiss(animated: true)
			self?.pairingClosed()
		})
		host.modalPresentationStyle = .formSheet
		host.isModalInPresentation = true
		presenter.present(host, animated: true)
	}

	private func pairingClosed() {
		pairingShown = false
		startListener()
		startBrowser()
	}

	private static func topViewController() -> UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
		while let presented = top?.presentedViewController { top = presented }
		return top
	}
}

@available(iOS 26.0, *)
private struct PairingView: View {
	let publish: WAPublishableService
	let subscribe: WASubscribableService
	let done: () -> Void

	var body: some View {
		NavigationStack {
			List {
				Section {
					DevicePairingView(.wifiAware(.connecting(to: publish, from: .userSpecifiedDevices))) {
						Label("Make this phone visible", systemImage: "antenna.radiowaves.left.and.right")
					} fallback: {
						Label("Pairing isn't available on this phone", systemImage: "xmark.circle")
					}
				} header: {
					Text("On one phone")
				}
				Section {
					DevicePicker(.wifiAware(.connecting(to: .userSpecifiedDevices, from: subscribe)), onSelect: { _ in }) {
						Label("Find the other phone", systemImage: "magnifyingglass")
					} fallback: {
						Label("Pairing isn't available on this phone", systemImage: "xmark.circle")
					}
				} header: {
					Text("On the other phone")
				} footer: {
					Text("Pick the visible phone, then follow the prompts on both. Each pair of phones only does this once. "
						+ "After that, a phone that hosts shows up under Join on the other, with no Wi-Fi network needed.")
				}
			}
			.navigationTitle("Pair a nearby phone")
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
		}
	}
}
