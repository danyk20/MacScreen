import Foundation
import CryptoKit
import os
import MSCore

public enum CipherError: Error, Equatable {
    case tooShort
    case authenticationFailed
    case replayed
    case counterExhausted
}

enum CipherNonce {
    /// 4 zero bytes followed by the counter, big-endian.
    static func make(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var w = ByteWriter(capacity: 12)
        w.zeros(4)
        w.u64(counter)
        do { return try ChaChaPoly.Nonce(data: w.data) } catch { throw CipherError.authenticationFailed }
    }
}

/// Media-channel sealer (PLAN §6.6). Thread-safe.
public final class PacketSealer {
    public static let headerSize = 12
    public static let tagSize = 16

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

    private func nextCounter() throws -> UInt64 {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard counter < UInt64.max else { throw CipherError.counterExhausted }
        counter += 1
        return counter
    }

    public func seal(type: UInt8, payload: Data) throws -> Data {
        let c = try nextCounter()
        var w = ByteWriter(capacity: PacketSealer.headerSize + payload.count + PacketSealer.tagSize)
        w.u8(type)
        w.u8(0)
        w.u16(0)
        w.u64(c)
        let header = w.data
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.seal(payload, using: key, nonce: CipherNonce.make(c), authenticating: header)
        } catch let e as CipherError {
            throw e
        } catch {
            throw CipherError.authenticationFailed
        }
        w.bytes(box.ciphertext)
        w.bytes(box.tag)
        return w.data
    }
}

/// Media-channel opener. Use from a single queue.
public final class PacketOpener {
    private let key: SymmetricKey
    private var window = ReplayWindow()

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func open(_ datagram: Data) throws -> (type: UInt8, counter: UInt64, payload: Data) {
        let d = Data(datagram)  // rebase indices (handles slices)
        let hs = PacketSealer.headerSize
        guard d.count >= hs + PacketSealer.tagSize else { throw CipherError.tooShort }
        var r = ByteReader(d)
        let type: UInt8
        let counter: UInt64
        do {
            type = try r.u8()
            _ = try r.u8()
            _ = try r.u16()
            counter = try r.u64()
        } catch { throw CipherError.tooShort }
        let header = d.prefix(hs)
        let ct = d.subdata(in: hs..<(d.count - PacketSealer.tagSize))
        let tag = d.suffix(PacketSealer.tagSize)
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: CipherNonce.make(counter), ciphertext: ct, tag: tag)
            plain = try ChaChaPoly.open(box, using: key, authenticating: header)
        } catch {
            throw CipherError.authenticationFailed
        }
        guard window.accept(counter) else { throw CipherError.replayed }
        return (type, counter, plain)
    }
}
