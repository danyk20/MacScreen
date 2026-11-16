import Foundation
import CryptoKit
import os

/// TCP control-channel sealer (PLAN §6.5). Nonce = 4 zero bytes + implicit u64 message counter.
public final class ControlSealer {
    private let key: SymmetricKey
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) {
        self.key = key
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Returns ciphertext || tag.
    public func seal(_ body: Data) throws -> Data {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard counter < UInt64.max else { throw CipherError.counterExhausted }
        let c = counter + 1
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.seal(body, using: key, nonce: CipherNonce.make(c))
        } catch let e as CipherError {
            throw e
        } catch {
            throw CipherError.authenticationFailed
        }
        counter = c
        var out = Data(box.ciphertext)
        out.append(box.tag)
        return out
    }
}

public final class ControlOpener {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Advances the message counter only on success.
    public func open(_ sealed: Data) throws -> Data {
        let d = Data(sealed)
        guard d.count >= PacketSealer.tagSize else { throw CipherError.tooShort }
        guard counter < UInt64.max else { throw CipherError.counterExhausted }
        let c = counter + 1
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: CipherNonce.make(c),
                                               ciphertext: d.prefix(d.count - PacketSealer.tagSize),
                                               tag: d.suffix(PacketSealer.tagSize))
            plain = try ChaChaPoly.open(box, using: key)
        } catch {
            throw CipherError.authenticationFailed
        }
        counter = c
        return plain
    }
}
