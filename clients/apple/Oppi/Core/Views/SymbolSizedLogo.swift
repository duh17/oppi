import UIKit

/// A logo asset (a square template vector) drawn at the size SF Symbols give
/// `reference` under a symbol configuration, so a brand mark sits beside the
/// symbols around it at their size and weight of presence. A vector asset
/// takes no symbol configuration itself, so each size is rendered once, as a
/// template that tints like a symbol.
@MainActor
enum SymbolSizedLogo {
    private static var cache: [String: UIImage] = [:]

    /// Nil when the asset is missing. `fallbackSide` sizes it if the
    /// reference symbol cannot be made.
    static func image(
        named name: String,
        reference: String,
        configuration: UIImage.SymbolConfiguration,
        fallbackSide: CGFloat
    ) -> UIImage? {
        let side = (UIImage(systemName: reference, withConfiguration: configuration)?.size.width ?? fallbackSide).rounded()
        let key = "\(name)|\(side)"
        if let cached = cache[key] { return cached }
        guard let logo = UIImage(named: name) else { return nil }
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            logo.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }
}
