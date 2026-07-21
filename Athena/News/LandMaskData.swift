// Placeholder — replaced by Scripts/make-coastline.py with real Natural Earth
// coastlines. Until then the globe falls back to the coarse built-in mask.
//
//     python3 Scripts/make-coastline.py
//
import Foundation

enum LandMaskData {
    static let columns = 0
    static let rows = 0
    static let degrees = 1.0
    static let packed = ""
    static let bits: [UInt8] = []

    static func isLand(row: Int, col: Int) -> Bool { false }
}
