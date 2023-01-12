import XCTest
@testable import Skiff
import KotlinKanji
import GryphonLib
import FairCore

final class SkiffTests: XCTestCase {
    func testBasic() throws {
        try check(swift: 6, kotlin: 6) {
            1 + 2 + 3
        } // check: 1 + 2 + 3

        try check(swift: "XYZ", kotlin: "XYZ") {
            "X" + "Y" + "Z"
        } // check: "X" + "Y" + "Z"

        try check(swift: 15, kotlin: 15) {
            [1, 5, 9].reduce(0, { x, y in x + y })
        } // check: listOf(1, 5, 9).fold(0, { x, y -> x + y })

        try check(swift: "dog", kotlin: "dog") {
            enum Pet : String {
                case cat, dog
            }
            return Pet.dog.rawValue.description
        } // check

        try check(swift: "meow", kotlin: "meow") {
            enum Pet : String {
                case cat, dog
            }
            switch Pet.cat {
            case .dog: return "woof"
            case .cat: return "meow"
            }
        } // check


//        try check(swift: 7, kotlin: 7) {
//            struct Thing {
//                let x, y: Int
//            }
//            let thing = Thing(x: 2, y: 5)
//            return thing.x + thing.y
//        } // check

    }

    @discardableResult func check<T : Equatable>(swift: T, kotlin: JSum, file: StaticString = #file, line: UInt = #line, block: () throws -> T) throws -> JSum {
        let k = try skiff(file: file, line: line)
        let result = try block()
        XCTAssertEqual(result, swift, "Swift values disagreed", file: file, line: line)
        XCTAssertEqual(k, kotlin, "Kotlin values disagreed", file: file, line: line)
        return k
    }

    func skiff(token: String = "} // check", file: StaticString = #file, line: UInt = #line) throws -> JSum {
        let code = try String(contentsOf: URL(fileURLWithPath: file.description))
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let initial = Array(lines[.init(line)...])
        guard let brace = initial.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(token) }) else {
            throw CocoaError(.formatting)
        }

        let checkString = initial[brace].trimmingCharacters(in: .whitespacesAndNewlines)
        let match: String?
        if checkString.hasPrefix(token + ": ") {
            match = String(checkString.dropFirst(token.count + 2))
        } else {
            match = nil
        }

        let parts = initial[..<brace]
        var swift = parts.joined(separator: "\n")
        swift = swift.replacingOccurrences(of: "return ", with: "") // force remove returns, which aren't valid in top-level Kotlin

        let kotlin = try translate(swift: swift, trimMain: true) // + (hasReturn ? "()" : "")

        dbg("kotlin:", kotlin.trimmingCharacters(in: .whitespacesAndNewlines))

        if let match = match {
            XCTAssertEqual(match.trimmingCharacters(in: .whitespacesAndNewlines), kotlin.trimmingCharacters(in: .whitespacesAndNewlines), "expected transpiled Kotlin mismatch", file: file, line: line)
        }
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
        // translated code is embedded in a `main` function by default – trim it out
        if trimMain {
            let tok = "fun main(args: Array<String>) {"
            if code.contains(tok) {
                code = code.replacingOccurrences(of: tok, with: "")
                    .trimmingTrailingCharacters(in: .whitespacesAndNewlines)
                    .trimmingTrailingCharacters(in: CharacterSet(charactersIn: "}"))
            }
        }

        return code
    }

    func check(swift: String, kotlin: String, trimMain: Bool = true, file: StaticString = #file, line: UInt = #line) throws {
        XCTAssertEqual(kotlin, try translate(swift: swift, trimMain: trimMain, file: file, line: line), file: file, line: line)
    }
}
