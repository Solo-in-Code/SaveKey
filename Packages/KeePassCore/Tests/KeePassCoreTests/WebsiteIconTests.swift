// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import KeePassCore

final class WebsiteIconTests: XCTestCase {
    func entry(title: String = "", url: String = "") -> KPEntry {
        let e = KPEntry()
        e.title = title
        e.url = url
        return e
    }

    func testHostForEntries() {
        XCTAssertEqual(WebsiteIcon.host(for: entry(url: "https://www.netflix.com/login?next=/browse&token=secret")), "netflix.com")
        XCTAssertEqual(WebsiteIcon.host(for: entry(url: "accounts.google.com")), "accounts.google.com")
        XCTAssertEqual(WebsiteIcon.host(for: entry(title: "Netflix")), "netflix.com", "known service by title")
        XCTAssertEqual(WebsiteIcon.host(for: entry(title: "Disney+")), "disneyplus.com")
        XCTAssertNil(WebsiteIcon.host(for: entry(title: "My bank")), "unknown titles are never guessed")
        XCTAssertNil(WebsiteIcon.host(for: entry(url: "http://192.168.1.1")), "local addresses are never contacted")
        XCTAssertNil(WebsiteIcon.host(for: entry(url: "https://nas.local:5001")))
        XCTAssertNil(WebsiteIcon.host(for: entry(url: "ssh://server.example.com")))
        XCTAssertNil(WebsiteIcon.host(for: entry(url: "androidapp://com.netflix.mediaclient")))
        XCTAssertEqual(WebsiteIcon.host(for: entry(title: "Netflix", url: "https://netflix.com")), "netflix.com")
    }

    func testPublicHostRules() {
        XCTAssertTrue(WebsiteIcon.isPublicHost("netflix.com"))
        XCTAssertTrue(WebsiteIcon.isPublicHost("bbc.co.uk"))
        XCTAssertTrue(WebsiteIcon.isPublicHost("xn--80ak6aa92e.com"))
        XCTAssertFalse(WebsiteIcon.isPublicHost("localhost"))
        XCTAssertFalse(WebsiteIcon.isPublicHost("10.0.0.1"))
        XCTAssertFalse(WebsiteIcon.isPublicHost("router.lan"))
        XCTAssertFalse(WebsiteIcon.isPublicHost("intranet"))
        XCTAssertFalse(WebsiteIcon.isPublicHost("my server.com"))
    }

    func testFindsBestIconInHTML() {
        let html = """
        <!doctype html><html><head>
        <meta charset="utf-8"><title>Netflix</title>
        <link rel="shortcut icon" href="https://assets.example.net/icons/favicon.ico">
        <LINK REL="apple-touch-icon" HREF="/icons/touch-180.png">
        <link rel='icon' type='image/png' sizes='32x32' href='//cdn.example.net/icon-32.png'>
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel="mask-icon" href="/safari-pinned.svg" color="#e50914">
        <link rel="icon" sizes="192x192" href="/icon-192.png?v=2&amp;x=1">
        <link rel="stylesheet" href="/style.css">
        </head><body><link rel="icon" href="/not-in-head.png"></body></html>
        """
        let urls = WebsiteIcon.iconCandidates(html: html, baseURL: URL(string: "https://www.example.com/en/")!)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://www.example.com/icon-192.png?v=2&x=1",
            "https://www.example.com/icons/touch-180.png",
            "https://cdn.example.net/icon-32.png",
            "https://assets.example.net/icons/favicon.ico",
        ])
    }

    func testUpgradesHttpAndSkipsDataURIs() {
        let html = #"<head><link rel="icon" href="http://example.com/a.png"><link rel="icon" href="data:image/png;base64,AAAA"></head>"#
        let urls = WebsiteIcon.iconCandidates(html: html, baseURL: URL(string: "https://example.com/")!)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/a.png"])
    }
}
