// sign-rules: the Ed25519 signature of rules database manifests (RulesManifest, Scripts/release/publish-rules.sh).
// Crypto only: the private key arrives on stdin (base64 of the 32 raw bytes) and is never written anywhere by this
// tool; Scripts/release/setup-keys.sh keeps it in the login keychain. Run with `xcrun swift main.swift …`.
//
//   generate                              prints "private <base64>" and "public <base64>" (a new key)
//   public                    < key        prints the public key
//   sign <file>               < key        prints the signature of the file's bytes (base64)
//   verify <file> <signature> <keys>       exit 0 when one of the comma-separated public keys made the signature
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("sign-rules: \(message)\n".utf8))
    exit(code)
}

func privateKeyFromStdin() -> Curve25519.Signing.PrivateKey {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("stdin is not a base64 Ed25519 private key")
    }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate" where arguments.count == 1:
    let key = Curve25519.Signing.PrivateKey()
    print("private \(key.rawRepresentation.base64EncodedString())")
    print("public \(key.publicKey.rawRepresentation.base64EncodedString())")
case "public" where arguments.count == 1:
    print(privateKeyFromStdin().publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 2:
    let key = privateKeyFromStdin()
    guard let signature = try? key.signature(for: read(arguments[1])) else { fail("signing failed", code: 1) }
    print(signature.base64EncodedString())
case "verify" where arguments.count == 4:
    guard let signature = Data(base64Encoded: arguments[2]) else { fail("the signature is not base64") }
    let message = read(arguments[1])
    let keys = arguments[3].split(separator: ",").compactMap {
        Data(base64Encoded: $0.trimmingCharacters(in: .whitespaces)).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }
    exit(keys.contains { $0.isValidSignature(signature, for: message) } ? 0 : 1)
default:
    fail("usage: generate | public < key | sign <file> < key | verify <file> <signature> <public keys>")
}
