import BigInt
import CryptoKit
import Foundation

/// HomeKit-style TLV8: type, length (<= 255), value; long values are split into consecutive fragments.
enum TLV8 {
    static let method: UInt8 = 0x00, salt: UInt8 = 0x02, publicKey: UInt8 = 0x03, proof: UInt8 = 0x04
    static let seqNo: UInt8 = 0x06, error: UInt8 = 0x07, flags: UInt8 = 0x13

    static func encode(_ items: [(UInt8, [UInt8])]) -> Data {
        var out = Data()
        for (type, value) in items {
            if value.isEmpty { out.append(contentsOf: [type, 0]); continue }
            var offset = 0
            while offset < value.count {
                let n = min(255, value.count - offset)
                out.append(type)
                out.append(UInt8(n))
                out.append(contentsOf: value[offset..<offset + n])
                offset += n
            }
        }
        return out
    }

    static func decode(_ data: Data) -> [UInt8: [UInt8]] {
        let bytes = [UInt8](data)
        var result = [UInt8: [UInt8]]()
        var previous: UInt8?
        var i = 0
        while i + 2 <= bytes.count {
            let type = bytes[i], length = Int(bytes[i + 1])
            let value = Array(bytes[(i + 2)..<min(bytes.count, i + 2 + length)])
            if type == previous { result[type, default: []] += value } else { result[type] = value }
            previous = type
            i += 2 + length
        }
        return result
    }
}

/// SRP-6a client with the HAP parameters (RFC 5054 3072-bit group, SHA-512), byte conventions as
/// used by Apple receivers: k and u use padded values, M1 and K use minimal big-endian values.
struct SRPClient {
    static let N = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
        + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
        + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
        + "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
        + "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
        + "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
        + "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
        + "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
        radix: 16)!
    static let g = BigUInt(5)
    static let length = 384

    let a = BigUInt.randomInteger(withExactWidth: 256)
    var A: BigUInt { Self.g.power(a, modulus: Self.N) }

    struct Result { let publicKey: [UInt8]; let proof: [UInt8]; let sessionKey: [UInt8]; let expectedServerProof: [UInt8] }

    func respond(salt: [UInt8], serverPublic B: BigUInt, username: String = "Pair-Setup", password: String) -> Result? {
        let N = Self.N
        guard B % N != 0 else { return nil }
        let A = self.A
        let k = BigUInt(Data(H(minimal(N) + pad(Self.g))))
        let u = BigUInt(Data(H(pad(A) + pad(B))))
        let x = BigUInt(Data(H(salt + H(Array("\(username):\(password)".utf8)))))
        let v = Self.g.power(x, modulus: N)
        let base = (B + N - (k * v) % N) % N
        let S = base.power(a + u * x, modulus: N)
        let K = H(minimal(S))
        let hN = H(minimal(N)), hg = H(minimal(Self.g))
        let xor = stripZeros(zip(hN, hg).map { $0 ^ $1 })
        let M1 = H(xor + stripZeros(H(Array(username.utf8))) + salt + minimal(A) + minimal(B) + K)
        let M2 = H(minimal(A) + M1 + K)
        return Result(publicKey: pad(A), proof: M1, sessionKey: K, expectedServerProof: M2)
    }

    private func H(_ bytes: [UInt8]) -> [UInt8] { Array(SHA512.hash(data: bytes)) }
    private func minimal(_ x: BigUInt) -> [UInt8] { [UInt8](x.serialize()) }
    private func pad(_ x: BigUInt) -> [UInt8] {
        let m = minimal(x)
        return [UInt8](repeating: 0, count: max(0, Self.length - m.count)) + m
    }
    private func stripZeros(_ bytes: [UInt8]) -> [UInt8] { Array(bytes.drop(while: { $0 == 0 })) }
}

enum HAPCrypto {
    static func hkdf(_ secret: [UInt8], salt: String, info: String) -> [UInt8] {
        let key = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(salt.utf8),
                                         info: Data(info.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Array($0) }
    }

    /// 12-byte nonce: 4 zero bytes, then the 64-bit counter little-endian.
    static func nonce(_ counter: UInt64) -> [UInt8] {
        [0, 0, 0, 0] + withUnsafeBytes(of: counter.littleEndian) { Array($0) }
    }

    static func seal(_ plaintext: [UInt8], key: SymmetricKey, nonce: [UInt8], aad: [UInt8]) -> [UInt8] {
        let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: try! ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    static func open(_ sealed: [UInt8], key: SymmetricKey, nonce: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return Array(try ChaChaPoly.open(box, using: key, authenticating: aad))
    }
}

/// HAP encrypted stream framing: [length: UInt16 LE][ciphertext][tag], at most 1024 plaintext bytes per frame,
/// the length bytes are the AAD and each direction counts its own nonces.
final class HAPSession {
    private let outKey: SymmetricKey, inKey: SymmetricKey
    private var outCounter: UInt64 = 0, inCounter: UInt64 = 0
    private var pending = [UInt8]()

    init(outKey: [UInt8], inKey: [UInt8]) {
        self.outKey = SymmetricKey(data: outKey)
        self.inKey = SymmetricKey(data: inKey)
    }

    func encrypt(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        repeat {
            let n = min(1024, data.count - offset)
            let length: [UInt8] = [UInt8(n & 0xff), UInt8(n >> 8)]
            out += length + HAPCrypto.seal(Array(data[offset..<offset + n]), key: outKey, nonce: HAPCrypto.nonce(outCounter), aad: length)
            outCounter += 1
            offset += n
        } while offset < data.count
        return out
    }

    /// Feeds received bytes; returns the plaintext of every complete frame.
    func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        pending += data
        var out = [UInt8]()
        while pending.count >= 2 {
            let n = Int(pending[0]) | Int(pending[1]) << 8
            guard pending.count >= 2 + n + 16 else { break }
            let length = Array(pending[0..<2])
            out += try HAPCrypto.open(Array(pending[2..<(2 + n + 16)]), key: inKey, nonce: HAPCrypto.nonce(inCounter), aad: length)
            inCounter += 1
            pending.removeFirst(2 + n + 16)
        }
        return out
    }
}
