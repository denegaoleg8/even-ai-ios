import SwiftUI

/// Semantic color tokens. Views should reference these, never raw
/// `Color(...)` or hex values, so the palette can be restyled from one
/// place.
enum AppColor {
    static let background = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let accent = Color.accentColor
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let bubbleUser = Color.accentColor
    static let bubbleAssistant = Color(.secondarySystemBackground)
    static let divider = Color(.separator)
    static let destructive = Color.red
}
