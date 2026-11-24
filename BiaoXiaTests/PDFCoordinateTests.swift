import XCTest
@testable import BiaoXia

final class PDFCoordinateTests: XCTestCase {
    func testTopLeftNormalizedRectConvertsToPDFCoordinates() {
        let normalized = NormalizedRect(x: 0.25, y: 0.20, width: 0.50, height: 0.10)
        let result = PDFExportService.pdfBounds(
            from: normalized,
            pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800)
        )

        XCTAssertEqual(result.origin.x, 150, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 560, accuracy: 0.001)
        XCTAssertEqual(result.width, 300, accuracy: 0.001)
        XCTAssertEqual(result.height, 80, accuracy: 0.001)
    }

    func testGeneralEngineUsesSameTopLeftCoordinateContract() {
        let normalized = NormalizedRect(x: 0.25, y: 0.20, width: 0.50, height: 0.10)
        let result = PDFFormEngine.pdfBounds(
            from: normalized,
            pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800)
        )

        XCTAssertEqual(result.origin.x, 150, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 560, accuracy: 0.001)
        XCTAssertEqual(result.width, 300, accuracy: 0.001)
        XCTAssertEqual(result.height, 80, accuracy: 0.001)
    }
}
