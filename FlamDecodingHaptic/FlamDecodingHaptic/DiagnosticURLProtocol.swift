//
//  DiagnosticURLProtocol.swift
//  FlamDecodingHaptic
//
//  A URLProtocol subclass used ONLY during "manifest-only" verification.
//
//  When active it:
//   • Allows the m3u8 manifest request through normally.
//   • Intercepts every .ts segment request and logs it — but also
//     lets it through so the test can optionally block segments entirely
//     by setting `blockSegments = true`.
//
//  This lets us prove that AHAP data (EXT-X-DATERANGE) is delivered
//  from the manifest BEFORE any segment bytes arrive.
//

import Foundation

final class DiagnosticURLProtocol: URLProtocol {

    // Set to true to drop all .ts requests (proves AHAP arrives without segments)
    static var blockSegments = false

    // Callback fired on main queue whenever any request is intercepted
    static var onRequest: ((String) -> Void)?

    private var sessionTask: URLSessionDataTask?

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        let url = request.url?.absoluteString ?? ""
        // Only intercept requests to our HLS server
        return url.contains(":8080")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let isSegment = url.hasSuffix(".ts")
        let isManifest = url.hasSuffix(".m3u8")
        let isAhap = url.hasSuffix(".ahap")

        let tag = isManifest ? "📄 m3u8" : isSegment ? "📦 .ts segment" : isAhap ? "🎵 .ahap" : "🌐 other"
        let msg = "\(tag): \(URL(string: url)?.lastPathComponent ?? url)"

        print("🔍 [DiagProto] \(msg)")
        DispatchQueue.main.async { DiagnosticURLProtocol.onRequest?(msg) }

        if isSegment && DiagnosticURLProtocol.blockSegments {
            // Silently drop the segment — client will stall but manifest is already loaded
            print("🚫 [DiagProto] Blocking segment: \(URL(string: url)?.lastPathComponent ?? "")")
            DispatchQueue.main.async {
                DiagnosticURLProtocol.onRequest?("🚫 BLOCKED: \(URL(string: url)?.lastPathComponent ?? "")")
            }
            // Return an empty 200 so AVFoundation doesn't error out immediately
            let empty = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: empty, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // Pass through normally using a plain URLSession
        let config  = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        sessionTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data     { self.client?.urlProtocol(self, didLoad: data) }
            if let error    { self.client?.urlProtocol(self, didFailWithError: error) }
            else            { self.client?.urlProtocolDidFinishLoading(self) }
        }
        sessionTask?.resume()
    }

    override func stopLoading() {
        sessionTask?.cancel()
    }
}
