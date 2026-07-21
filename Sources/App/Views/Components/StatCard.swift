import SwiftUI

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        BTCard {
            VStack(alignment: .leading, spacing: BTSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.btSecondaryText)
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.btText)
                Text(title)
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
