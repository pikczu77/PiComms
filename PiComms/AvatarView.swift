import SwiftUI
import UIKit

struct AvatarView: View {
    let imageData: Data?
    let name: String
    let size: CGFloat

    init(profile: Profile?, size: CGFloat) {
        self.imageData = profile?.avatar
        self.name = profile?.displayName ?? ""
        self.size = size
    }

    init(imageData: Data?, name: String, size: CGFloat) {
        self.imageData = imageData
        self.name = name
        self.size = size
    }

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.accentColor.opacity(0.7), .accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(.white)
                    } else {
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
    }
}

enum ImageProcessing {
    /// Przycina zdjęcie do kwadratu, zmniejsza do 256×256 i kompresuje do JPEG,
    /// żeby plik profilu na Drive był mały (ok. 20–40 KB).
    static func avatarJPEG(from data: Data, side: CGFloat = 256) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = side / min(size.width, size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (side - scaled.width) / 2, y: (side - scaled.height) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let result = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
        return result.jpegData(compressionQuality: 0.8)
    }
}
