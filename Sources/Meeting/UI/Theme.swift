import SwiftUI

/// A small, deliberate design system. Default-everything is what makes SwiftUI
/// apps look generic — a real type ramp and a two-accent palette is most of the
/// distance to looking designed.
enum Theme {
    /// Mic track — warm. "You".
    static let mic = Color(red: 0.98, green: 0.62, blue: 0.31)
    /// System track — cool. "Them".
    static let system = Color(red: 0.42, green: 0.71, blue: 0.98)
    static let recording = Color(red: 0.98, green: 0.36, blue: 0.38)

    static func accent(for source: AudioSource) -> Color {
        source == .mic ? mic : system
    }

    /// The detail pane's background.
    ///
    /// Opaque, so the reading surface is a flat sheet rather than the desktop
    /// showing through it — a translucent material behind a long transcript
    /// picks up whatever wallpaper is underneath and changes as the window
    /// moves. The sidebar keeps its material, which is what gives the split the
    /// usual macOS depth.
    ///
    /// `textBackgroundColor` rather than literal white: it is the system's own
    /// colour for a content surface, so it stays white in light appearance and
    /// goes properly dark in dark appearance instead of blinding you.
    static let content = Color(nsColor: .textBackgroundColor)

    enum Font {
        static let display = SwiftUI.Font.system(size: 34, weight: .semibold, design: .rounded)
        static let timer = SwiftUI.Font.system(size: 44, weight: .medium, design: .rounded)
            .monospacedDigit()
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 14, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
            .monospacedDigit()
        static let label = SwiftUI.Font.system(size: 10, weight: .bold)
    }

    static let corner: CGFloat = 14

    /// Room a page must leave at its foot for a bar floating over it.
    ///
    /// The bar's own height plus its gap: content scrolls *behind* it, so
    /// without this the last line stops under the bar with no way to reach it.
    static let barClearance: CGFloat = 112
}

/// Chrome for the floating surfaces: an inset, rounded, shadowed slab rather
/// than a full-width strip welded to the window edge.
///
/// Shared by the record footer and the playback transport because they are the
/// same object in two places — the controls for whatever the pane is doing. They
/// had each grown their own copy of the padding and material, which is how they
/// drift apart.
///
/// Shape is a parameter because the bar and the panel that rises out of it want
/// different ones — a capsule reads as a control, but a 300pt-tall capsule is
/// just a lozenge with a screen inside it.
struct FloatingChrome<S: Shape>: ViewModifier {
    static var corner: CGFloat { 18 }
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(Theme.content, in: shape)
            .overlay {
                shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            // Solid, not glass. The bar floats over the page in playback, so a
            // material was tempting — but text sliding under the controls is
            // exactly what hurts their legibility, and a white surface is what
            // keeps a bar readable against a page of words.
            //
            // The shadow does the separating: bar and pane are the same colour,
            // so depth is all that divides them. Applied outside the background
            // rather than to the filled shape, which is where it belongs.
            .shadow(color: .black.opacity(0.16), radius: 16, y: 5)
    }
}

extension View {
    /// The bottom bar itself.
    ///
    /// Width comes from the row inside it: give one element `maxWidth:
    /// .infinity` — the waveform, the scrubber — and the bar fills the pane and
    /// tightens with it.
    ///
    /// Deliberately *not* `.frame(maxWidth: .infinity)` here. Demanding
    /// unbounded width at this level propagates up through the pane and
    /// collapses the split view's detail column to nothing, which renders blank
    /// and stays blank — the failure `ContentView` warns about above its own
    /// frame modifiers.
    /// - Parameter maxWidth: caps how wide the bar may grow. A *finite* cap is
    ///   safe; `.infinity` here is not, per the note above.
    func floatingBar(maxWidth: CGFloat? = nil) -> some View {
        self
            // Wider than the panel's inset: a capsule's ends curve away, so
            // square padding would let the first control graze the edge.
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: maxWidth)
            .modifier(FloatingChrome(shape: Capsule(style: .continuous)))
            .padding(.horizontal, 16)
            // Generous, because the gap is what sells the float — a bar close to
            // the window edge reads as docked to it no matter how round it is.
            .padding(.bottom, 24)
    }

    /// A panel that rises out of the bottom bar and shares its edges.
    ///
    /// No inner padding — the content fills the slab and is clipped to it, so a
    /// screen still meets the rounded corners rather than sitting in a frame.
    func floatingPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self
            .clipShape(shape)
            .modifier(FloatingChrome(shape: shape))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    /// Dissolves content into the page at its foot.
    ///
    /// For a page that runs under a floating bar: without it the last visible
    /// line is sliced by the bar's edge, and half a row of text reads as a
    /// rendering fault rather than as something to scroll to.
    ///
    /// The gradient starts from `Theme.content` at zero opacity, not
    /// `Color.clear` — clear is black with no alpha, and interpolating towards
    /// it drags a grey cast through the middle of the fade.
    func bottomFade(height: CGFloat = 96) -> some View {
        overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Theme.content.opacity(0), Theme.content],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }

    /// The reading column: full width up to 720, then centred.
    ///
    /// Past roughly that width the eye loses the start of the next line, which
    /// is why prose is set to a measure rather than to the window.
    ///
    /// No horizontal padding — the cap is the inset. Adding both would narrow
    /// the text twice and leave it off the header's line.
    func measure() -> some View {
        self
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
    }
}

extension TimeInterval {
    /// Built by hand rather than with `String(format:)`, which goes through
    /// varargs and a format parser. That is irrelevant once, and very much not
    /// irrelevant once per transcript line per render pass.
    var clockString: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        var out = ""
        out.reserveCapacity(8)
        if hours > 0 {
            out += String(hours)
            out.append(":")
            out.appendPadded(minutes)
        } else {
            out.appendPadded(minutes)
        }
        out.append(":")
        out.appendPadded(seconds)
        return out
    }
}

private extension String {
    /// Two digits, zero-padded. Only ever called with 0...59.
    mutating func appendPadded(_ value: Int) {
        if value < 10 { append("0") }
        append(String(value))
    }
}
