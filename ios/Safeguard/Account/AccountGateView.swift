import SwiftUI

struct AccountGateView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                Image("LaunchLogo")
                    .resizable().scaledToFit()
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                AccountFlowView()
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DS.Colors.background.ignoresSafeArea())
    }
}
