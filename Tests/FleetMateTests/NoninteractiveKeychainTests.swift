import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import FleetMateCore

final class NoninteractiveKeychainTests: XCTestCase {
    func testModernQueriesNeverPermitAuthenticationUI() throws {
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "example", kSecReturnData as String: true]
        let query = NoninteractiveKeychain.query(attributes as CFDictionary) as! [String: Any]
        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "example")
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    }

    func testEveryOperationDisablesLegacyKeychainInteraction() throws {
        try withTemporaryKeychain { keychain in
            let match = self.match(keychain)
            var add = self.attributes()
            add[kSecUseKeychain as String] = keychain
            add[kSecValueData as String] = Data("fixture".utf8)
            let values = [kSecValueData as String: Data("updated fixture".utf8)]
            var read = match
            read[kSecReturnData as String] = true
            let operations: [() -> OSStatus] = [
                { NoninteractiveKeychain.add(add as CFDictionary, nil) },
                { NoninteractiveKeychain.copyMatching(read as CFDictionary, nil) },
                { NoninteractiveKeychain.update(match as CFDictionary, values as CFDictionary) },
                { NoninteractiveKeychain.delete(match as CFDictionary) },
            ]
            for operation in operations {
                // This vault is unlocked and its fixture is owned by this test process,
                // so enabling the default policy here cannot prompt for a user credential.
                XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)
                XCTAssertEqual(operation(), errSecSuccess)
                var allowed = DarwinBoolean(true)
                XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
                XCTAssertFalse(allowed.boolValue)
            }
        }
    }

    func testLockedLegacyKeychainReturnsWithoutAUserPrompt() throws {
        try withTemporaryKeychain { keychain in
            var add = self.attributes()
            add[kSecUseKeychain as String] = keychain
            add[kSecValueData as String] = Data("fixture".utf8)
            XCTAssertEqual(NoninteractiveKeychain.add(add as CFDictionary, nil), errSecSuccess)
            var query = self.match(keychain)
            query[kSecReturnData as String] = true
            var data: CFTypeRef?
            XCTAssertEqual(NoninteractiveKeychain.copyMatching(query as CFDictionary, &data), errSecSuccess)
            XCTAssertEqual(data as? Data, Data("fixture".utf8))
            XCTAssertEqual(SecKeychainLock(keychain), errSecSuccess)
            let started = Date()
            let status = NoninteractiveKeychain.copyMatching(query as CFDictionary, &data)
            XCTAssertNotEqual(status, errSecSuccess)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            var allowed = DarwinBoolean(true)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertFalse(allowed.boolValue)
        }
    }

    private func attributes() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "example.noninteractive-keychain",
         kSecAttrAccount as String: "fixture"]
    }

    private func match(_ keychain: SecKeychain) -> [String: Any] {
        var query = attributes()
        query[kSecMatchSearchList as String] = [keychain]
        return query
    }

    private func withTemporaryKeychain(_ body: (SecKeychain) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.keychain").path
        let password = "fixture-only"
        var keychain: SecKeychain?
        let status = path.withCString { path in
            password.withCString { passwordBytes in
                SecKeychainCreate(path, UInt32(password.utf8.count), passwordBytes, false, nil, &keychain)
            }
        }
        XCTAssertEqual(status, errSecSuccess)
        let vault = try XCTUnwrap(keychain)
        defer {
            _ = password.withCString { SecKeychainUnlock(vault, UInt32(password.utf8.count), $0, true) }
            _ = SecKeychainDelete(vault)
        }
        try body(vault)
    }
}
