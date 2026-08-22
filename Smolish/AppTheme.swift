import SwiftUI

extension Color {
    static let smolishBlue = Color(red: 29 / 255, green: 161 / 255, blue: 242 / 255)
    static let smolishPurple = Color(red: 158 / 255, green: 20 / 255, blue: 255 / 255)
    static let smolishBlack = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
}

struct SmolishLogo: View {
    var size: CGFloat = 32

    var body: some View {
        Image("SmolishLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Smolish")
    }
}


