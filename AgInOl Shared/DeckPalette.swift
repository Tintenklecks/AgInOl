//
//  DeckPalette.swift
//  AgInOl — shared by the Mac app and the companion
//
//  Palette matched to the Neo Agent Deck reference. Shared so the
//  companion renders the same colours the deck does.
//

import SwiftUI

enum DeckColor {
    static let green  = Color(red: 0.22, green: 0.87, blue: 0.45)
    static let amber  = Color(red: 1.00, green: 0.72, blue: 0.10)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.26)
    static let cyan   = Color(red: 0.35, green: 0.78, blue: 0.98)
    static let purple = Color(red: 0.72, green: 0.60, blue: 0.99)
    static let magenta = Color(red: 0.95, green: 0.35, blue: 0.65)
    static let gray   = Color(white: 0.62)

    // Tile card backgrounds
    static let greenTile  = Color(red: 0.09, green: 0.23, blue: 0.15)
    static let amberTile  = Color(red: 0.29, green: 0.20, blue: 0.05)
    static let grayTile   = Color(red: 0.15, green: 0.16, blue: 0.19)
    static let oliveTile  = Color(red: 0.26, green: 0.19, blue: 0.04)
    static let brownTile  = Color(red: 0.25, green: 0.13, blue: 0.06)
    static let blueTile   = Color(red: 0.06, green: 0.15, blue: 0.25)
    static let purpleTile = Color(red: 0.15, green: 0.11, blue: 0.27)
    static let magentaTile = Color(red: 0.28, green: 0.08, blue: 0.16)
    static let indigoTile = Color(red: 0.18, green: 0.13, blue: 0.30)

    static let screen = Color(red: 0.05, green: 0.055, blue: 0.07)
}

extension SnapshotPalette {
    var tint: Color {
        switch self {
        case .claude:   DeckColor.orange
        case .codex:    DeckColor.cyan
        case .kimi:     DeckColor.magenta
        case .opencode: DeckColor.purple
        case .neutral:  DeckColor.gray
        }
    }

    var tileBackground: Color {
        switch self {
        case .claude:   DeckColor.brownTile
        case .codex:    DeckColor.blueTile
        case .kimi:     DeckColor.magentaTile
        case .opencode: DeckColor.purpleTile
        case .neutral:  DeckColor.grayTile
        }
    }
}

extension SnapshotAgentStatus {
    var tint: Color {
        switch self {
        case .working:  DeckColor.green
        case .needsYou: DeckColor.amber
        case .idle:     DeckColor.gray
        case .offline:  Color(white: 0.35)
        }
    }

    var tileBackground: Color {
        switch self {
        case .working:  DeckColor.greenTile
        case .needsYou: DeckColor.amberTile
        case .idle:     DeckColor.grayTile
        case .offline:  Color(red: 0.10, green: 0.10, blue: 0.12)
        }
    }
}
