import XCTest
import CSystemSupport
import CryptoKit
@testable import Videx

final class BrowserCookieTests: XCTestCase {
    func testFirefoxSnapshotFiltersDomainsAndPreservesSessionCookies() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("videx-firefox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE moz_cookies(host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,isSecure INTEGER); INSERT INTO moz_cookies VALUES('.youtube.com','SAPISID','test','/',0,1); INSERT INTO moz_cookies VALUES('.example.com','secret','ignored','/',9999999999,1);"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let jar = try BrowserCookies.firefox(database: file)
        XCTAssertEqual(jar.cookies.count, 1)
        XCTAssertEqual(jar.header(for: URL(string: "https://www.youtube.com/")!), "SAPISID=test")
        XCTAssertNil(jar.header(for: URL(string: "http://www.youtube.com/")!))
    }
    func testChromiumPBKDFGoldenValue() throws {
        let key = try BrowserCookies.deriveKey(Data("test-password".utf8))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "c0ffe4c25f07f62bfc6ab011d9efa54e")
    }
    func testChromiumHostnameBoundCookieDecryptsWithoutRealKeychain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("videx-chrome-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let password = Data("test-password".utf8), host = ".youtube.com"
        let key = try BrowserCookies.deriveKey(password)
        let plaintext = Data(SHA256.hash(data: Data(host.utf8))) + Data("test-value".utf8)
        var output = Data(count: plaintext.count + 16), length = 0
        let capacity = output.count, iv = Data(repeating: 32, count: 16)
        let status = output.withUnsafeMutableBytes { out in plaintext.withUnsafeBytes { input in key.withUnsafeBytes { k in iv.withUnsafeBytes { vector in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, 16, vector.baseAddress, input.baseAddress, plaintext.count, out.baseAddress, capacity, &length)
        } } } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        let encrypted = Data("v10".utf8) + output.prefix(length)
        XCTAssertEqual(try BrowserCookies.decrypt(encrypted, key: key, host: host, version: 24), "test-value")
        XCTAssertThrowsError(try BrowserCookies.decrypt(encrypted, key: key, host: ".example.com", version: 24))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let hex = encrypted.map { String(format: "%02x", $0) }.joined()
        let sql = "CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','24'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER); INSERT INTO cookies VALUES('.youtube.com','SAPISID','',X'\(hex)','/',0,1);"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let jar = try BrowserCookies.chromium(database: file, password: { password })
        XCTAssertEqual(jar.cookies.first?.value, "test-value")
    }
    func testSafariBinaryCookiePage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("videx-safari-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        func le(_ n: UInt32) -> Data { Data((0..<4).map { UInt8((n >> ($0*8)) & 255) }) }
        func be(_ n: UInt32) -> Data { Data((0..<4).reversed().map { UInt8((n >> ($0*8)) & 255) }) }
        var cookie = Data(repeating: 0, count: 56)
        func set(_ n: UInt32, at offset: Int) { cookie.replaceSubrange(offset..<offset+4, with: le(n)) }
        set(1, at: 8)
        for (field, value) in [(16, ".youtube.com"), (20, "SAPISID"), (24, "/"), (28, "test-value")] {
            set(UInt32(cookie.count), at: field); cookie += Data(value.utf8) + Data([0])
        }
        set(UInt32(cookie.count), at: 0)
        let expiry = Double(9_000_000_000).bitPattern
        cookie.replaceSubrange(40..<48, with: Data((0..<8).map { UInt8((expiry >> ($0*8)) & 255) }))
        let page = Data([0,0,1,0]) + le(1) + le(16) + le(0) + cookie
        let data = Data("cook".utf8) + be(1) + be(UInt32(page.count)) + page
        try data.write(to: file)
        let jar = try BrowserCookies.safari(file: file)
        XCTAssertEqual(jar.cookies.first?.value, "test-value")
        XCTAssertEqual(jar.cookies.first?.domain, ".youtube.com")
    }
}
