import Foundation
import CryptoKit
import CSystemSupport
#if os(macOS)
import Security
#endif

/// Imports only YouTube cookies from a browser profile explicitly selected by the caller.
/// SQLite's read-only online backup includes WAL data and does not modify the browser DB.
public enum BrowserCookies {
    public static func firefox(database: URL) throws -> CookieJar {
        let db = try snapshot(database)
        defer { sqlite3_close(db) }
        return try query(db, sql: "SELECT host,name,value,path,expiry,isSecure FROM moz_cookies WHERE host='.youtube.com' OR host='youtube.com' OR host='www.youtube.com'") { row in
            SiteCookie(name: string(row,1), value: string(row,2), domain: string(row,0), path: string(row,3),
                       expires: sqlite3_column_double(row,4) > 0 ? sqlite3_column_double(row,4) : nil, secure: sqlite3_column_int(row,5) != 0)
        }
    }
    public static func chromium(database: URL, keychainService: String = "Chrome Safe Storage") throws -> CookieJar {
        #if os(macOS)
        return try chromium(database: database) {
            let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
                                       kSecAttrService as String:keychainService,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
            var value: CFTypeRef?
            let result = SecItemCopyMatching(query as CFDictionary,&value)
            guard result == errSecSuccess,let data=value as? Data else { throw ExtractionError.loginRequired(site:"youtube",reason:"无法读取浏览器 Safe Storage 钥匙串：\(result)") }
            return data
        }
        #else
        throw ExtractionError.notExtractable(site:"youtube",reason:"Chromium 浏览器 Cookie 导入目前需要 macOS 系统钥匙串")
        #endif
    }
    static func chromium(database: URL, password: () throws -> Data) throws -> CookieJar {
        let db = try snapshot(database)
        defer { sqlite3_close(db) }
        var version = 0, statement: OpaquePointer?
        if sqlite3_prepare_v2(db,"SELECT value FROM meta WHERE key='version'",-1,&statement,nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW { version=Int(string(statement,0)) ?? 0 }
        sqlite3_finalize(statement)
        var key: Data?
        return try query(db,sql:"SELECT host_key,name,value,encrypted_value,path,expires_utc,is_secure FROM cookies WHERE host_key='.youtube.com' OR host_key='youtube.com' OR host_key='www.youtube.com'") { row in
            let host=string(row,0),plain=string(row,2)
            let value:String
            let encrypted=blob(row,3)
            if !plain.isEmpty || encrypted.isEmpty { value=plain }
            else {
                if key==nil { key=try deriveKey(password()) }
                value=try decrypt(encrypted,key:key!,host:host,version:version)
            }
            let chromeExpiry=sqlite3_column_double(row,5)
            let expiry=chromeExpiry>0 ? chromeExpiry/1_000_000-11_644_473_600 : 0
            return SiteCookie(name:string(row,1),value:value,domain:host,path:string(row,4),expires:expiry>0 ? expiry:nil,secure:sqlite3_column_int(row,6) != 0)
        }
    }
    static func deriveKey(_ password: Data) throws -> Data {
        let salt=Data("saltysalt".utf8)
        var key=Data(count:16)
        let status=key.withUnsafeMutableBytes { output in password.withUnsafeBytes { pass in salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),pass.baseAddress?.assumingMemoryBound(to:CChar.self),password.count,
                salt.baseAddress?.assumingMemoryBound(to:UInt8.self),salt.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),1003,
                output.baseAddress?.assumingMemoryBound(to:UInt8.self),16)
        } } }
        guard status==kCCSuccess else { throw ExtractionError.parse("浏览器 Cookie 密钥派生失败") }
        return key
    }
    static func decrypt(_ encrypted: Data, key: Data, host: String, version: Int) throws -> String {
        guard encrypted.starts(with:Data("v10".utf8)) || encrypted.starts(with:Data("v11".utf8)) else {
            throw ExtractionError.parse("浏览器 Cookie 加密版本不支持；请导出 cookies.txt")
        }
        var clear=try NativeHLSDownloader.decrypt(Data(encrypted.dropFirst(3)),key:key,iv:Data(repeating:32,count:16))
        if version>=24 {
            let digest=Data(SHA256.hash(data:Data(host.utf8)))
            guard clear.prefix(32)==digest else { throw ExtractionError.parse("浏览器 Cookie 域摘要校验失败") }
            clear=Data(clear.dropFirst(32))
        }
        guard let value=String(data:clear,encoding:.utf8) else { throw ExtractionError.parse("浏览器 Cookie 不是 UTF-8") }
        return value
    }
    public static func safari(file: URL) throws -> CookieJar {
        let data=try Data(contentsOf:file)
        guard data.prefix(4)==Data("cook".utf8),data.count>=8 else { throw ExtractionError.parse("Safari binarycookies 文件无效") }
        func integer(_ data:Data,_ offset:Int,_ big:Bool=false) throws -> Int {
            guard offset>=0,offset+4<=data.count else { throw ExtractionError.parse("Safari Cookie 页截断") }
            let values=Array(data[offset..<offset+4])
            return values.enumerated().reduce(0) { $0 | Int($1.element) << ((big ? 3-$1.offset:$1.offset)*8) }
        }
        let count=try integer(data,4,true)
        guard count<=10000,8+count*4<=data.count else { throw ExtractionError.parse("Safari Cookie 页表无效") }
        var offset=8+count*4,jar=CookieJar()
        for index in 0..<count {
            let size=try integer(data,8+index*4,true)
            guard size>=8,offset+size<=data.count else { throw ExtractionError.parse("Safari Cookie 页大小无效") }
            let page=Data(data[offset..<offset+size]);offset+=size
            let cookies=try integer(page,4)
            guard cookies<=100000,8+cookies*4<=page.count else { throw ExtractionError.parse("Safari Cookie 偏移表无效") }
            for index in 0..<cookies {
                let cookieOffset=try integer(page,8+index*4)
                let cookieSize=try integer(page,cookieOffset)
                guard cookieSize>=56,cookieOffset+cookieSize<=page.count else { throw ExtractionError.parse("Safari Cookie 长度无效") }
                let cookie=Data(page[cookieOffset..<cookieOffset+cookieSize])
                func text(_ field:Int) throws -> String {
                    let start=try integer(cookie,field)
                    guard start>=0,start<cookie.count,let end=cookie[start...].firstIndex(of:0),
                          let value=String(data:cookie[start..<end],encoding:.utf8) else { throw ExtractionError.parse("Safari Cookie 字符串无效") }
                    return value
                }
                let host=try text(16)
                guard [".youtube.com","youtube.com","www.youtube.com"].contains(host) else { continue }
                let flags=try integer(cookie,8)
                let raw=Array(cookie[40..<48]).enumerated().reduce(UInt64(0)){$0 | UInt64($1.element) << ($1.offset*8)}
                let expiry=Double(bitPattern:raw)+978_307_200
                jar.set(SiteCookie(name:try text(20),value:try text(28),domain:host,path:try text(24),expires:expiry,secure:flags&1 != 0))
            }
        }
        return jar
    }
    static func snapshot(_ url:URL) throws -> OpaquePointer {
        var source:OpaquePointer?,destination:OpaquePointer?
        guard sqlite3_open_v2(url.path,&source,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,let source else { sqlite3_close(source);throw ExtractionError.parse("无法读取指定的浏览器 Cookie 数据库") }
        defer{sqlite3_close(source)}
        guard sqlite3_open(":memory:",&destination)==SQLITE_OK,let destination else { sqlite3_close(destination);throw ExtractionError.parse("Cookie 快照创建失败") }
        guard let backup=sqlite3_backup_init(destination,"main",source,"main") else { sqlite3_close(destination);throw ExtractionError.parse("Cookie 数据库快照失败") }
        var status=sqlite3_backup_step(backup,-1),attempts=0
        while [SQLITE_BUSY,SQLITE_LOCKED].contains(status),attempts<10 { sqlite3_sleep(20);status=sqlite3_backup_step(backup,-1);attempts+=1 }
        sqlite3_backup_finish(backup)
        guard status==SQLITE_DONE else { sqlite3_close(destination);throw ExtractionError.parse("浏览器 Cookie 数据库忙，请稍后重试") }
        return destination
    }
    static func query(_ db:OpaquePointer,sql:String,row:(OpaquePointer)->SiteCookie) throws -> CookieJar {
        try query(db,sql:sql,throwingRow:row)
    }
    static func query(_ db:OpaquePointer,sql:String,throwingRow:(OpaquePointer)throws->SiteCookie) throws -> CookieJar {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement else { throw ExtractionError.parse("浏览器 Cookie 表结构不兼容") }
        defer{sqlite3_finalize(statement)}
        var jar=CookieJar(),status=sqlite3_step(statement)
        while status==SQLITE_ROW {
            let cookie=try throwingRow(statement)
            if cookie.expires.map({$0>Date().timeIntervalSince1970}) ?? true { jar.set(cookie) }
            status=sqlite3_step(statement)
        }
        guard status==SQLITE_DONE else{throw ExtractionError.parse("浏览器 Cookie 查询失败")}
        return jar
    }
    static func string(_ row:OpaquePointer?,_ column:Int32)->String{sqlite3_column_text(row,column).map{String(cString:$0)} ?? ""}
    static func blob(_ row:OpaquePointer?,_ column:Int32)->Data{
        guard let data=sqlite3_column_blob(row,column) else{return Data()}
        return Data(bytes:data,count:Int(sqlite3_column_bytes(row,column)))
    }
}
