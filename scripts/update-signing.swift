// Güncelleme imzası (Ed25519). scripts/release.sh kullanır.
//
//   swift scripts/update-signing.swift generate          → gizli anahtar (base64) stdout'a, açık anahtar stderr'e
//   swift scripts/update-signing.swift public            → stdin'deki gizli anahtarın açık anahtarı
//   swift scripts/update-signing.swift sign <dosya>      → stdin'deki gizli anahtarla imza (base64)
//   swift scripts/update-signing.swift verify <dosya> <imza> <açık anahtar>
//
// Gizli anahtar komut satırında değil stdin'den alınır (süreç listesinde görünmesin).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readPrivateKey() -> Curve25519.Signing.PrivateKey {
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: input),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("Gizli anahtar okunamadı") }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Okunamadı: \(path)") }
    return data
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    FileHandle.standardError.write(Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8))
case "public":
    print(readPrivateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 2:
    let signature = try readPrivateKey().signature(for: read(arguments[arguments.startIndex + 1]))
    print(signature.base64EncodedString())
case "verify" where arguments.count == 4:
    let list = Array(arguments)
    guard let signature = Data(base64Encoded: String(decoding: read(list[2]), as: UTF8.self)
              .trimmingCharacters(in: .whitespacesAndNewlines)),
          let keyData = Data(base64Encoded: list[3]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("İmza ya da anahtar okunamadı") }
    guard key.isValidSignature(signature, for: read(list[1])) else { fail("İmza GEÇERSİZ") }
    print("İmza geçerli")
default:
    fail("Kullanım: generate | public | sign <dosya> | verify <dosya> <imza> <açık anahtar>")
}
