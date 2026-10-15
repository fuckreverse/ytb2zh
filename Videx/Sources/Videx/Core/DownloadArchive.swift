import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// Only successful, existing outputs are archived. Writes are atomic and guarded by a file lock.
public actor DownloadArchive {
    public let url: URL
    struct Record: Codable { var output: String; var bytes: UInt64; var completedAt: Date }
    public init(url: URL) { self.url = url }
    public func contains(_ key: String) throws -> Bool {
        try locked {
            guard let record=try records()[key], let size=(try? FileManager.default.attributesOfItem(atPath:record.output)[.size] as? NSNumber)?.uint64Value else{return false}
            return size>0 && size==record.bytes
        }
    }
    public func record(_ key:String, output:URL) throws {
        try locked {
            let size=(try FileManager.default.attributesOfItem(atPath:output.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard size>0 else{throw ExtractionError.parse("不能归档空的下载结果")}
            var all=try records();all[key]=Record(output:output.path,bytes:size,completedAt:Date())
            try JSONEncoder().encode(all).write(to:url,options:.atomic)
        }
    }
    private func records() throws->[String:Record]{
        guard FileManager.default.fileExists(atPath:url.path) else{return [:]}
        return try JSONDecoder().decode([String:Record].self,from:Data(contentsOf:url))
    }
    private func locked<T>(_ body:()throws->T)throws->T{
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        #if canImport(Darwin)
        let descriptor=Darwin.open(url.appendingPathExtension("lock").path,O_CREAT|O_RDWR,0o600)
        guard descriptor>=0,flock(descriptor,LOCK_EX)==0 else{throw ExtractionError.parse("下载归档锁定失败")}
        defer{flock(descriptor,LOCK_UN);Darwin.close(descriptor)}
        #endif
        return try body()
    }
}

public struct BatchDownloadResult: Codable, Sendable {
    public var id:String
    public var url:URL
    public var status:String
    public var output:URL?
    public var error:String?
}
public enum BatchDownloadRunner {
    public static func run(urls:[URL],directory:URL,archive:DownloadArchive?=nil,stopOnError:Bool=false,
                           delaySeconds:Double=5,
                           download:@Sendable(URL,URL)async throws->URL)async throws->[BatchDownloadResult]{
        var results:[BatchDownloadResult]=[],seen=Set<String>()
        for url in urls{
            try Task.checkCancellation()
            let id=YouTubeURL.videoID(from:url) ?? SHA256.hash(data:Data(url.absoluteString.utf8)).prefix(8).map{String(format:"%02x",$0)}.joined()
            guard seen.insert(id).inserted else{continue}
            let key="youtube "+id
            if try await archive?.contains(key)==true{results.append(BatchDownloadResult(id:id,url:url,status:"archived"));continue}
            let target=directory.appendingPathComponent(id).appendingPathComponent("source.mp4")
            do{
                let output=try await download(url,target)
                try await archive?.record(key,output:output)
                results.append(BatchDownloadResult(id:id,url:url,status:"complete",output:output))
            }catch is CancellationError{throw CancellationError()}
            catch{
                results.append(BatchDownloadResult(id:id,url:url,status:"failed",error:error.localizedDescription))
                if stopOnError{throw error}
            }
            if delaySeconds>0{try await Task.sleep(for:.seconds(min(60,delaySeconds)))}
        }
        return results
    }

    public static func playlistURLs(query:String,limit:Int=200,options:ExtractionOptions=ExtractionOptions())async throws->[URL]{
        let service=YouTubeSearchService()
        var urls:[URL]=[],seen=Set<String>(),offset=0
        while urls.count<max(0,limit){
            let page=try await service.fetchPage(query:query,offset:offset,proxy:options.proxy ?? "", cookies: options.cookies)
            guard !page.items.isEmpty else{break}
            for item in page.videos where seen.insert(item.id).inserted{
                urls.append(YouTubeURL.watchURL(id:item.id))
                if urls.count>=limit{break}
            }
            offset+=page.items.count
            if page.continuation==nil{break}
        }
        return urls
    }
}
