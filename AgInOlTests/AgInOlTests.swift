//
//  AgInOlTests.swift
//  AgInOlTests
//
//  Created by puco on 18.07.2026.
//

import Testing
@testable import AgInOl

struct AgInOlTests {
    @Test func deckGridOffersOneThroughSixRowsAndColumns() {
        #expect(AppSettings.columnOptions == Array(1...6))
        #expect(AppSettings.rowOptions == Array(1...6))
    }
}
