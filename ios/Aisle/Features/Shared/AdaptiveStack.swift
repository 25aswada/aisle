import SwiftUI

/// Lays buttons side by side, or stacked when the user picks an accessibility text size.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing, content: content)
        } else {
            HStack(spacing: spacing, content: content)
        }
    }
}
