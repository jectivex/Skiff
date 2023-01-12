import XCTest
@testable import Skiff
import KotlinKanji
import GryphonLib
import FairCore

final class SkiffTests: XCTestCase {
    func testBasic() throws {
        XCTAssertEqual(6, try skiff {
            1 + 2 + 3
        })
        
        XCTAssertEqual("xyz", try skiff {
            "x" + "y" + "z"
        })

    }

    func skiff<T>(file: StaticString = #file, line: Int = #line, block: () -> T) throws -> JSum {
        let code = try String(contentsOf: URL(fileURLWithPath: file.description))
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let initial = Array(lines[line...])
        guard let brace = initial.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "})" }) else {
            throw CocoaError(.formatting)
        }

        let parts = initial[..<brace]

        let swift = parts.joined(separator: "\n")

        let kotlin = try translate(swift: swift, trimMain: true)

        let ctx = try KotlinContext()
        return try ctx.eval(.val(.str(kotlin))).jsum()
    }

    func testKotlinScript() throws {
        let ctx = try KotlinContext()
        XCTAssertEqual(3, try ctx.eval("1+2").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 'a'; 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 'a'; 1+2 }()").jsum())
        //XCTAssertEqual(3, try ctx.eval("return 1+2").jsum())
        // XCTAssertEqual(3, try ctx.eval("{ val x = 1+2; return x }()").jsum())
    }

    func testSimpleTranslation() throws {
        try check(swift: "1+2", kotlin: "1 + 2")
        try check(swift: "{ return 1+2 }", kotlin: "{ 1 + 2 }")
        try check(swift: #""abc"+"def""#, kotlin: #""abc" + "def""#)
        try check(swift: #"[1,2,3].map({ x in "Number: \(x)" })"#, kotlin: #"listOf(1, 2, 3).map({ x -> "Number: ${x}" })"#)

        try check(swift: "enum ENM : String { case abc, xyz }", kotlin: """
        internal enum class ENM(val rawValue: String) {
            ABC(rawValue = "abc"),
            XYZ(rawValue = "xyz");

            companion object {
                operator fun invoke(rawValue: String): ENM? = values().firstOrNull { it.rawValue == rawValue }
            }
        }
        """)
    }

    func testTranslateFunction() throws {
        let swift = """
        func getMessage() -> String {
            return "Hello from Gryphon!"
        }

        print(getMessage())
        """

        let kotlin = """
        internal fun getMessage(): String {
            return "Hello from Gryphon!"
        }

        fun main(args: Array<String>) {
            println(getMessage())
        }

        """

        try check(swift: swift, kotlin: kotlin, trimMain: false)
    }

    enum TranslateError : Error {
        case noResult
        case noInitialResult
        case noInitialTranslationResult
    }

    func translate(swift: String, trimMain: Bool = true, file: StaticString = #file, line: UInt = #line) throws -> String {
        let fileURL = URL(fileURLWithPath: UUID().uuidString, isDirectory: false, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)).appendingPathExtension("swift")
        try swift.write(to: fileURL, atomically: true, encoding: .utf8)

        guard let result = try Driver.run(withArguments: [fileURL.path]) else {
            throw TranslateError.noResult
        }

        guard let list = result as? List<Any?> else {
            throw TranslateError.noInitialResult
        }

        guard let translation = list.first as? Driver.KotlinTranslation else {
            throw TranslateError.noInitialTranslationResult
        }

        var code = translation.kotlinCode
        if trimMain {
            code = (code as NSString)
                .replacingOccurrences(of: "fun main(args: Array<String>)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if code.hasSuffix("}") && code.hasPrefix("{") {
                code = String(code.dropFirst().dropLast())
            }
            code = code
                .trimmingCharacters(in: .whitespacesAndNewlines)

        }

        return code
    }

    func check(swift: String, kotlin: String, trimMain: Bool = true, file: StaticString = #file, line: UInt = #line) throws {
        XCTAssertEqual(kotlin, try translate(swift: swift, trimMain: trimMain, file: file, line: line), file: file, line: line)
    }
}
