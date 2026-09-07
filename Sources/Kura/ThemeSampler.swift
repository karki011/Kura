// ThemeSampler — auto light/dark card theme: samples the average luminance of the screen
// region BELOW the overlay every 2s (one-shot still capture, no recording indicator,
// uses the Screen Recording grant the user already gave). Falls back gracefully to the
// manual theme if capture is unavailable.
import AppKit
import CoreGraphics

@MainActor
final class ThemeSampler: ObservableObject {
    static let shared = ThemeSampler()

    @Published private(set) var suggestsLight = false

    private weak var panel: NSWindow?
    private var timer: Timer?

    func start(panel: NSWindow) {
        guard self.panel == nil else { return }
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        // AppKit frames are bottom-left origin; Quartz wants top-left global coords.
        let screenHeight = NSScreen.screens.map(\.frame.maxY).max() ?? frame.maxY
        let rect = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
        guard let image = CGWindowListCreateImage(rect, .optionOnScreenBelowWindow,
                                                  CGWindowID(panel.windowNumber), [.nominalResolution]) else { return }
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var luminance = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            luminance += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
        }
        luminance /= Double(size * size) * 255.0
        let light = luminance > 0.55
        if light != suggestsLight { suggestsLight = light }
    }
}
