import Foundation

/// Third-party notice for the Thinking Orbs geometry used by Oppi's Metal
/// working and dictation indicators.
enum ThinkingOrbAttribution {
    static let title = "Thinking Orbs"
    static let summary =
        "Oppi adapts Thinking Orbs geometry for Working, Searching, Solving, Composing, and Breathing. Jakub Antalik created the original thinking-orbs designs and engine. Haplo LLC made the Swift ThinkingOrbs port. Oppi adds Metal rasterization and voice-reactive motion; this is not original Oppi artwork."
    static let originalDesignURLString = "https://github.com/Jakubantalik/thinking-orbs"
    static let swiftPortURLString = "https://github.com/haplollc/ThinkingOrbs"
    static var originalDesignURL: URL {
        URL(string: originalDesignURLString) ?? URL(fileURLWithPath: "/")
    }
    static var swiftPortURL: URL {
        URL(string: swiftPortURLString) ?? URL(fileURLWithPath: "/")
    }
    static let sourceCommit = "e2c07bbdec4db797fb302300ef0159b1806a909f"

    /// Full MIT text with both copyrights, as required by the upstream license.
    static let licenseText = """
    MIT License

    Copyright (c) 2026 Haplo LLC
    Copyright (c) 2026 Jakub Antalik (the original thinking-orbs designs and engine)

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
