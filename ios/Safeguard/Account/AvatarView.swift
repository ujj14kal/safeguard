import SwiftUI
import UIKit

struct AvatarView: View {
    var data: Data?
    var name: String
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    DS.Colors.accent.opacity(0.25)
                    Text(AvatarImage.initials(name))
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(String(localized: "Profile photo"))
    }
}
