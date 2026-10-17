import AppKit
import SwiftUI

// MARK: - Zoom de la escala de la app

/// En macOS SwiftUI ignora `dynamicTypeSize`, así que el zoom es un
/// multiplicador propio (`\.zoomScale`) aplicado sobre tamaños de letra
/// explícitos. La base de cada estilo se lee del sistema, no de una tabla.
let zoomStepMin = -2
let zoomStepMax = 5

func clampedZoomStep(_ step: Int) -> Int {
    min(max(step, zoomStepMin), zoomStepMax)
}

/// Escala geométrica del paso de zoom (1.0 = tamaño normal).
func zoomScale(forZoomStep step: Int) -> Double {
    switch clampedZoomStep(step) {
    case -2: return 0.8
    case -1: return 0.9
    case 0: return 1.0
    case 1: return 1.125
    case 2: return 1.25
    case 3: return 1.5
    case 4: return 1.75
    default: return 2.0
    }
}

private struct ZoomScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var zoomScale: Double {
        get { self[ZoomScaleKey.self] }
        set { self[ZoomScaleKey.self] = newValue }
    }
}

/// Tamaño en puntos de un estilo de texto a la escala dada.
func zoomPointSize(for style: NSFont.TextStyle, scale: Double) -> CGFloat {
    NSFont.preferredFont(forTextStyle: style).pointSize * scale
}

/// Fuente escalada equivalente al estilo del sistema.
func zoomFont(
    _ style: NSFont.TextStyle, scale: Double,
    weight: Font.Weight = .regular, design: Font.Design = .default
) -> Font {
    .system(size: zoomPointSize(for: style, scale: scale), weight: weight, design: design)
}
