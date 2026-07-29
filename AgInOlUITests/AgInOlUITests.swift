//
//  AgInOlUITests.swift
//  AgInOlUITests
//
//  Created by puco on 18.07.2026.
//

import XCTest

final class AgInOlUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {}

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()
        snapshot("0Launch")
    }
}
