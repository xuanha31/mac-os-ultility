import XCTest
@testable import GitManagerModule

final class GitTests: XCTestCase {

    func testParseSSHGitHub() {
        let ref = RepoCorrelator.parse(remoteURL: "git@github.com:acme/widgets.git")
        XCTAssertEqual(ref?.kind, .github)
        XCTAssertEqual(ref?.host, "github.com")
        XCTAssertEqual(ref?.fullPath, "acme/widgets")
        XCTAssertEqual(ref?.owner, "acme")
        XCTAssertEqual(ref?.repo, "widgets")
        XCTAssertEqual(ref?.apiBaseURL?.absoluteString, "https://api.github.com")
    }

    func testParseHTTPSGitLabSubgroup() {
        let ref = RepoCorrelator.parse(remoteURL: "https://gitlab.com/group/sub/widgets.git")
        XCTAssertEqual(ref?.kind, .gitlab)
        XCTAssertEqual(ref?.host, "gitlab.com")
        XCTAssertEqual(ref?.fullPath, "group/sub/widgets")
        XCTAssertEqual(ref?.repo, "widgets")
        XCTAssertEqual(ref?.apiBaseURL?.absoluteString, "https://gitlab.com/api/v4")
    }

    func testParseEnterpriseGitHub() {
        let ref = RepoCorrelator.parse(remoteURL: "https://github.example.com/team/app.git")
        XCTAssertEqual(ref?.kind, .github)
        XCTAssertEqual(ref?.apiBaseURL?.absoluteString, "https://github.example.com/api/v3")
    }

    func testParseUnknownHost() {
        let ref = RepoCorrelator.parse(remoteURL: "git@bitbucket.org:team/app.git")
        XCTAssertEqual(ref?.kind, .unknown)
        XCTAssertNil(ref?.apiBaseURL)
    }
}
