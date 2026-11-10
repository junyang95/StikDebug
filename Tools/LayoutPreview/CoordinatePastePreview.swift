import SwiftUI

enum CoordinatePastePreview {
    static let sample = """
    25.097467, 121.712822
    25.140071, 121.709084
    25.127901, 121.736764
    25.127658, 121.742311
    25.120645, 121.723095
    25.144918, 121.726561
    25.136060, 121.786835
    25.081714, 121.695951
    25.045210, 121.516140
    25.046086, 121.513379
    25.043461, 121.523968
    25.044278, 121.508594
    25.041508, 121.545018
    25.082686, 121.546370
    25.060373, 121.525384
    25.027568, 121.563322
    25.052054, 121.555007
    25.057341, 121.517810
    25.059314, 121.617931
    """

    static func page(_ name: String) -> AnyView {
        let text = name == "coordinates-invalid" ? "25.097467, 121.712822\n1. 25.140071, 121.709084\n95, 121.736764"
            : name == "coordinates-single" ? "25.097467, 121.712822" : sample
        return AnyView(CoordinateEntrySheet(initialText: text, speedKilometersPerHour: 8,
                                           prefersRoute: name != "coordinates-single",
                                           onApply: { _, _ in }, onApplyRoute: { _ in }))
    }
}
