import SwiftUI

/// Semantic type tokens, built on Dynamic Type text styles so the app
/// respects the user's preferred text size out of the box.
enum AppTypography {
    static let screenTitle = Font.largeTitle.weight(.bold)
    static let chatTitle = Font.headline
    static let chatPreview = Font.subheadline
    static let messageBody = Font.body
    static let timestamp = Font.caption
    static let sectionHeader = Font.footnote.weight(.semibold)
}
