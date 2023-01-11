import XCTest
@testable import Skiff
import KotlinKanji
import GryphonLib

final class SkiffTests: XCTestCase {
    func testTranspilation() throws {
        let ctx = try KotlinContext()
        XCTAssertEqual(3, try ctx.eval("1+2").jsum())
    }
}
