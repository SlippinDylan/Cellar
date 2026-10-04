import Foundation

struct OfficialNodeReleaseClient: Sendable {
    let http: CatalogHTTPClient
    init(http: CatalogHTTPClient = CatalogHTTPClient()) { self.http = http }
    func releases() async throws -> [OfficialNodeRelease] {
        let data = try await http.data(from: CatalogWebsites.url(host: "nodejs.org", path: "/dist/index.json"))
        let releases = try JSONDecoder().decode([OfficialNodeRelease].self, from: data)
        return Array(releases.filter {
            $0.version.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
                && $0.files.contains("osx-arm64-tar")
        }.prefix(100))
    }
}
