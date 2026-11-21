import XCTest
@testable import KimiBar

final class TestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private(set) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class FakeCredentialStore: KimiCredentialStoring {
    var stored: KimiCredentials?
    var onSave: (() -> Void)?
    private(set) var deleteCount = 0

    func loadCredentials() throws -> KimiCredentials? { stored }
    func saveCredentials(_ credentials: KimiCredentials) throws {
        onSave?()
        stored = credentials
    }
    func deleteCredentials() throws {
        stored = nil
        deleteCount += 1
    }
}
