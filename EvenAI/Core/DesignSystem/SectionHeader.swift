import SwiftUI

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(AppTypography.sectionHeader)
            .foregroundStyle(AppColor.textSecondary)
    }
}

#Preview {
    SectionHeader(title: "Preview Features")
}
