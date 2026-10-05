import Foundation

/// One physical keyboard and pointer, with ownership for each remote client.
/// All access to the underlying MacInputController is serialized by `lock`.
final class SharedInputController: @unchecked Sendable {
    private struct HeldKey {
        let keysym: UInt32
        let mapAltToCommand: Bool
        var owners: Set<UUID>
    }

    private struct PointerPosition {
        let x: UInt16
        let y: UInt16
        let layout: VirtualDisplayLayout
    }

    private let input: InputController
    private let lock = NSLock()
    private var keys: [UInt16: HeldKey] = [:]
    private var buttons: [UUID: UInt8] = [:]
    private var activeClients: Set<UUID> = []
    private var pointerClient: UUID?
    private var position: PointerPosition?

    init(input: InputController) { self.input = input }

    func makeClient() -> InputController { Client(owner: self) }

    private func key(client: UUID, down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
        lock.lock()
        defer { lock.unlock() }
        activeClients.insert(client)
        // Resolve physical keys before counting owners: Apple's Alt_L and a
        // standard viewer's Meta_L can both represent the same Command key.
        let code = KeySymMapper.modifier(for: keysym, mapAltToCommand: mapAltToCommand)?.keyCode
            ?? KeySymMapper.keyCode(for: keysym)
        guard let code else {
            // Unmapped Unicode text is emitted as an immediate down/up pair.
            input.key(down: down, keysym: keysym, mapAltToCommand: mapAltToCommand)
            return
        }
        if down {
            if var held = keys[code] {
                let repeating = held.owners.contains(client)
                held.owners.insert(client)
                keys[code] = held
                if repeating {
                    input.key(down: true, keysym: held.keysym, mapAltToCommand: held.mapAltToCommand)
                }
            } else {
                keys[code] = HeldKey(keysym: keysym, mapAltToCommand: mapAltToCommand, owners: [client])
                input.key(down: true, keysym: keysym, mapAltToCommand: mapAltToCommand)
            }
        } else {
            releaseKey(code, client: client)
        }
    }

    private func releaseKey(_ code: UInt16, client: UUID) {
        guard var held = keys[code], held.owners.remove(client) != nil else { return }
        if held.owners.isEmpty {
            keys[code] = nil
            input.key(down: false, keysym: held.keysym, mapAltToCommand: held.mapAltToCommand)
        } else {
            keys[code] = held
        }
    }

    private var buttonMask: UInt8 { buttons.values.reduce(0, |) }

    private func pointer(client: UUID, mask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        lock.lock()
        defer { lock.unlock() }
        activeClients.insert(client)
        if pointerClient != client { input.resetClickSequence() }
        pointerClient = client
        position = PointerPosition(x: x, y: y, layout: layout)
        buttons[client] = mask & 7 == 0 ? nil : mask & 7
        // Wheel bits belong to this packet; only held buttons are aggregated.
        input.pointer(buttonMask: buttonMask | (mask & 0xf8), x: x, y: y, layout: layout)
    }

    private func release(client: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard activeClients.remove(client) != nil else { return }
        for code in Array(keys.keys).sorted() { releaseKey(code, client: client) }
        let previousMask = buttonMask
        buttons[client] = nil
        if previousMask != buttonMask, let position {
            // Release at the current shared pointer, not the departing client's
            // old position, and preserve buttons still held by other viewers.
            input.pointer(buttonMask: buttonMask, x: position.x, y: position.y, layout: position.layout)
        }
        if pointerClient == client {
            pointerClient = nil
            input.resetClickSequence()
        }
        if activeClients.isEmpty { input.releaseKeys() }
    }

    private final class Client: InputController {
        private let owner: SharedInputController
        private let id = UUID()
        init(owner: SharedInputController) { self.owner = owner }
        deinit { owner.release(client: id) }
        func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
            owner.key(client: id, down: down, keysym: keysym, mapAltToCommand: mapAltToCommand)
        }
        func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
            owner.pointer(client: id, mask: buttonMask, x: x, y: y, layout: layout)
        }
        func releaseKeys() { owner.release(client: id) }
    }
}
