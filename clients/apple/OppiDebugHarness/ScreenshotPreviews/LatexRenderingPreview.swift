#if DEBUG
import Foundation
import SwiftUI

// MARK: - LaTeX Rendering Preview

struct LatexRenderingPreview: View {
    private static let markdown = #"""
    Ordinary assistant prose uses the same body text for scale and wrapping.

    Inline math: $x^2 + y^2 = z^2$ and \(\alpha \leq \beta\) appear within this sentence.

    If historical quota snapshots exist, use the smallest stable lookback that covers several sessions:

    - \(\mathrm{target\_burn} = R / T\)
    - \(\mathrm{recent\_burn} = \max(0, R_{\mathrm{prev}} - R_{\mathrm{now}}) / \mathrm{lookback}\), smoothed over that window using the same unit as T
    - \(\mathrm{pace\_ratio} = \mathrm{recent\_burn} \times T / R\)

    The formulas above should align with this surrounding selectable text, not replace or shrink it.

    **Displayed formula**

    $$
    \frac{1}{2} + \frac{1}{3} = \frac{5}{6}
    $$

    **Wide formula — tap to inspect**

    $$
    \begin{aligned}
    \mathbf H &= \mathbf X^\top\mathbf W\mathbf X+\lambda\mathbf I,\\
    \Delta\theta &= -\mathbf H^{-1}\nabla_\theta\mathcal L,\\
    \begin{bmatrix}x_{t+1}\\v_{t+1}\end{bmatrix}
    &=
    \begin{bmatrix}1&\Delta t\\0&1\end{bmatrix}
    \begin{bmatrix}x_t\\v_t\end{bmatrix}
    +
    \begin{bmatrix}\frac12\Delta t^2\\\Delta t\end{bmatrix}a_t.
    \end{aligned}
    $$

    Normal chat text continues below the displayed formula.
    """#

    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Production chat LaTeX rendering")
                    .font(.headline)
                    .foregroundStyle(.themeFg)

                Text("Exact physical-device regression payload")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                MarkdownContentViewWrapper(content: Self.markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("latex.preview.content")
            }
            .padding(20)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
