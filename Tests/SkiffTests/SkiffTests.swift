import XCTest
@testable import Skiff
import KotlinKanji
import GryphonLib
import FairCore


final class SkiffTests: XCTestCase {
    static let kotlinContext = Result { try KotlinContext() }

    var ctx: KotlinContext {
        get throws {
            try Self.kotlinContext.get()
        }
    }

    func testSimpleTranslation() throws {
        try compare(swift: "1+2", kotlin: "1 + 2")
        try compare(swift: "{ return 1+2 }", kotlin: "{ 1 + 2 }")
        try compare(swift: #""abc"+"def""#, kotlin: #""abc" + "def""#)
        try compare(swift: #"[1,2,3].map({ x in "Number: \(x)" })"#, kotlin: #"listOf(1, 2, 3).map({ x -> "Number: ${x}" })"#)

        try compare(swift: "enum ENM : String { case abc, xyz }", kotlin: """
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

        println(getMessage())
        """

        try compare(swift: swift, kotlin: kotlin)
    }

    enum TranslateError : Error {
        case noResult
        case noInitialResult
        case noInitialTranslationResult
    }

    func testBasic() throws {
        try check(swift: 6, kotlin: 6) {
            1+2+3
        } expect: {
            "1 + 2 + 3"
        }

        try check(swift: 6, kotlin: 6) {
            1.0+2.0+3.0
        } expect: {
            "1.0 + 2.0 + 3.0"
        }

        try check(swift: "XYZ", kotlin: "XYZ") {
            "X" + "Y" + "Z"
        } expect: {
            #""X" + "Y" + "Z""#
        }
    }

    func testListConversions() throws {
        try check(swift: 15, kotlin: 15) {
            [1, 5, 9].reduce(0, { x, y in x + y })
        } expect: {
            "listOf(1, 5, 9).fold(0, { x, y -> x + y })"
        }
    }

    func testEnumToEnum() throws {
        try check(swift: "dog", kotlin: "dog") {
            enum Pet : String {
                case cat, dog
            }
            return Pet.dog.rawValue.description
        } expect: {
            """
            internal enum class Pet(val rawValue: String) {
                CAT(rawValue = "cat"),
                DOG(rawValue = "dog");

                companion object {
                    operator fun invoke(rawValue: String): Pet? = values().firstOrNull { it.rawValue == rawValue }
                }
            }

            Pet.DOG.rawValue.toString()
            """
        }

        try check(swift: "meow", kotlin: "meow") {
            enum Pet : String {
                case cat, dog
            }
            var pet = Pet.dog
            pet = pet == .dog ? .cat : .dog
            switch pet {
            case .dog: return "woof" // nice doggy
            case .cat: return "meow" // cute kitty
            }
        } expect: {
            """
            internal enum class Pet(val rawValue: String) {
                CAT(rawValue = "cat"),
                DOG(rawValue = "dog");

                companion object {
                    operator fun invoke(rawValue: String): Pet? = values().firstOrNull { it.rawValue == rawValue }
                }
            }

            internal var pet: Pet = Pet.DOG

            pet = if (pet == Pet.DOG) { Pet.CAT } else { Pet.DOG }

            when (pet) {
                Pet.DOG -> "woof"
                Pet.CAT -> "meow"
            }
            """
        }
    }

    func testStructToDataClass() throws {
        try check(swift: 7, kotlin: 7) {
            struct Thing {
                var x, y: Int
            }
            let thing = Thing(x: 2, y: 5)
            return thing.x + thing.y
        } expect: {
            """
            internal data class Thing(
                var x: Int,
                var y: Int
            )

            internal val thing: Thing = Thing(x = 2, y = 5)

            thing.x + thing.y
            """
        }
    }

    /// This is a known and unavoidable difference in the behavior of Swift and Kotlin: data classes are passed by reference
    func testMutableStructsBehaveDifferently() throws {
        try check(swift: 12, kotlin: 13) {
            struct Thing {
                var x, y: Int
            }
            var thing = Thing(x: 0, y: 0)
            thing.x = 5
            thing.y = 7
            var t2 = thing
            // Swift structs are value types but Kotlin data classes are references, so this will work differently
            t2.x += 1
            return thing.x + thing.y
        } expect: {
            """
            internal data class Thing(
                var x: Int,
                var y: Int
            )

            internal var thing: Thing = Thing(x = 0, y = 0)

            thing.x = 5
            thing.y = 7

            internal var t2: Thing = thing

            // Swift structs are value types but Kotlin data classes are references, so this will work differently
            t2.x += 1

            thing.x + thing.y
            """
        }

    }

    @discardableResult func check<T : Equatable>(swift: T, kotlin: JSum, file: StaticString = #file, line: UInt = #line, block: () throws -> T, expect: () -> String?) throws -> JSum {
        let (k, j) = try skiff(file: file, line: line)
        let result = try block()
        if let expected = expect(), expected.trimmed().isEmpty == false {
            XCTAssertEqual(expected.trimmed(), k.trimmed(), "Expected source disagreed", file: file, line: line)
        } else {
            dbg("missing Kotlin expectation for:", k)
        }
        XCTAssertEqual(result, swift, "Swift values disagreed", file: file, line: line)
        XCTAssertEqual(j, kotlin, "Kotlin values disagreed", file: file, line: line)
        return j
    }

    func compare(swift: String, kotlin: String, file: StaticString = #file, line: UInt = #line) throws {
        XCTAssertEqual(kotlin.trimmed(), try translate(swift: swift, file: file, line: line).trimmed(), file: file, line: line)
    }

    func translate(swift: String, file: StaticString = #file, line: UInt = #line) throws -> String {
        let fileURL = URL(fileURLWithPath: UUID().uuidString, isDirectory: false, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)).appendingPathExtension("swift")

        //#warning("TODO: compile in-memory")
        try swift.write(to: fileURL, atomically: true, encoding: .utf8)

        // --quiet prevents the translated code from being output to the console
        // --no-main-file skips wrapping the output in a main fun
        guard let result = try Driver.performCompilation(withArguments: ["--no-main-file", "--quiet", fileURL.path]) else {
            throw TranslateError.noResult
        }

        guard let list = result as? List<Any?> else {
            throw TranslateError.noInitialResult
        }

        guard let translation = list.first as? Driver.KotlinTranslation else {
            throw TranslateError.noInitialTranslationResult
        }

        let code = translation.kotlinCode
        // translated code is embedded in a `main` function by default – trim it out

//        if trimMain {
//            let tok = "fun main(args: Array<String>) {"
//            if code.contains(tok) {
//                code = code.replacingOccurrences(of: tok, with: "")
//                    .trimmingTrailingCharacters(in: .whitespacesAndNewlines)
//                    .trimmingTrailingCharacters(in: CharacterSet(charactersIn: "}"))
//                    .trimmingTrailingCharacters(in: .whitespacesAndNewlines)
//            }
//        }

        return code
    }

    func skiff(token: String = "} expect: {", file: StaticString = #file, line: UInt = #line) throws -> (source: String, result: JSum) {
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

        let kotlin = try translate(swift: swift) // + (hasReturn ? "()" : "")

        //dbg("kotlin:", kotlin.trimmingCharacters(in: .whitespacesAndNewlines))

        if let match = match {
            XCTAssertEqual(match.trimmingCharacters(in: .whitespacesAndNewlines), kotlin.trimmingCharacters(in: .whitespacesAndNewlines), "expected transpiled Kotlin mismatch", file: file, line: line)
        }
        return (kotlin, try ctx.eval(.val(.str(kotlin))).jsum())
    }

    /// Run a few simple simple Kotlin snippets and check their output
    func testKotlinSnippets() throws {
        XCTAssertEqual(3, try ctx.eval("1+2").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 'a'; 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 'a'; 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ val x = 3; x }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ val x = 2; var y = 1; x + y; }()").jsum())
        //XCTAssertEqual(3, try ctx.eval("return 1+2").jsum())
        //XCTAssertEqual(3, try ctx.eval("{ val x = 1+2; return x }()").jsum())
    }
}
