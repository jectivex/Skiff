import XCTest
@testable import Skiff
import KotlinKanji
import JavaLib
import GryphonLib
import JSum

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
            return "Hello Skiff!"
        }

        print(getMessage())
        """

        let kotlin = """
        internal fun getMessage(): String {
            return "Hello Skiff!"
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
        try check(swift: 6, kotlin: 6) { _ in
            1+2+3
        } verify: {
            "1 + 2 + 3"
        }

        try check(swift: 6, kotlin: 6) { _ in
            1.0+2.0+3.0
        } verify: {
            "1.0 + 2.0 + 3.0"
        }

        try check(swift: "XYZ", kotlin: "XYZ") { _ in
            "X" + "Y" + "Z"
        } verify: {
            #""X" + "Y" + "Z""#
        }
    }

    func testListConversions() throws {
        try check(swift: [10], kotlin: [10]) { _ in
            (1...10).filter({ $0 > 9 })
        } verify: {
            "(1..10).filter({ it > 9 })"
        }

        try check(swift: [2, 3, 4], kotlin: [2, 3, 4]) { _ in
            [1, 2, 3].map({ $0 + 1 })
        } verify: {
            "listOf(1, 2, 3).map({ it + 1 })"
        }

        try check(swift: 15, kotlin: 15) { _ in
            [1, 5, 9].reduce(0, { x, y in x + y })
        } verify: {
            "listOf(1, 5, 9).fold(0, { x, y -> x + y })"
        }

        // demonstration that Gryphone mis-translates anonymous closure parameters beyond $0
        try check(compile: false, swift: 15, kotlin: 15) { _ in
            [1, 5, 9].reduce(0, { $0 + $1 })
        } verify: {
            "listOf(1, 5, 9).fold(0, { it + $1 })"
        }
    }

    func testEnumToEnum() throws {
        try check(swift: "dog", kotlin: "dog") { _ in
            enum Pet : String {
                case cat, dog
            }
            return Pet.dog.rawValue.description
        } verify: {
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

        try check(swift: "meow", kotlin: "meow") { _ in
            enum Pet : String {
                case cat, dog
            }
            var pet = Pet.dog
            pet = pet == .dog ? .cat : .dog
            switch pet {
            case .dog: return /* noreturn */ "woof" // nice doggy
            case .cat: return /* noreturn */ "meow" // cute kitty
            }
        } verify: {
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
        try check(swift: 7, kotlin: 7) { _ in
            struct Thing {
                var x, y: Int
            }
            let thing = Thing(x: 2, y: 5)
            return thing.x + thing.y
        } verify: {
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

    func testTranslationComments() throws {
        var tmpdir = NSTemporaryDirectory()
        #if os(Linux)
        let jtmpdir = tmpdir.trimmingTrailingCharacters(in: CharacterSet(["/"]))
        #else
        let jtmpdir = tmpdir
        #endif

        try check(autoport: true, swift: String?.some(tmpdir), java: String?.some(jtmpdir), kotlin: .str(jtmpdir)) { jvm in
            func tmpdir() throws -> String? {
                if jvm {
                    return try java$lang$System.getProperty(java$lang$String("java.io.tmpdir"))?.toSwiftString()
                } else {
                    return /* gryphon value: null */ NSTemporaryDirectory()
                }
            }

            return /* noreturn */ try tmpdir()
        } verify: {
            """
             fun tmpdir(): String? {
                if (jvm) {
                    return java.lang.System.getProperty(("java.io.tmpdir"))
                }
                else {
                    return null
                }
            }

            tmpdir()
            """
        }
    }

    /// This is a known and unavoidable difference in the behavior of Swift and Kotlin: data classes are passed by reference
    func testMutableStructsBehaveDifferently() throws {
        try check(swift: 12, kotlin: .num(12 + 1)) { _ in
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
        } verify: {
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

    func testFunctionBuilder() throws {
        @resultBuilder
        struct StringCharacterCounterBuilder {
            static func buildBlock(_ strings: String...) -> [Int] {
                return strings.map { $0.count }
            }
        }

        class CharacterCounter {
            let counterArray: [Int]

            init(@StringCharacterCounterBuilder _ content: () -> [Int]) {
                counterArray = content()
            }

            func showCounts() {
                counterArray.forEach { print($0) }
            }
        }

        let characterCounts = CharacterCounter {
            "Andy"
            "Ibanez"
            "Collects Pullip"
        }

        XCTAssertEqual([4, 6, 15], characterCounts.counterArray)
    }

    func testGenerateFunctionBuilder() throws {
        // does not compile, so we do not verify:

        // failed: caught error: "ERROR Data class must have at least one primary constructor parameter (ScriptingHost54e041a4_Line_6.kts:1:50)

        try check(compile: false, swift: [4, 6, 15], kotlin: [4, 6, 15]) { _ in
            @resultBuilder // FIXME: Gryphon does not grok @resultBuilder
            struct StringCharacterCounterBuilder {
                static func buildBlock(_ strings: String...) -> [Int] {
                    return strings.map { $0.count }
                }
            }

            class CharacterCounter {
                let counterArray: [Int]

                init(@StringCharacterCounterBuilder _ content: () -> [Int]) {
                    counterArray = content()
                }

                func showCounts() {
                    counterArray.forEach { print($0) }
                }
            }

            let characterCounts = CharacterCounter {
                "Andy" // this outputs uncompilable Kotlin
                "Ibanez" // (no commas between elements)
                "Collects Pullip"
            }

            return characterCounts.counterArray
        } verify: {
        """
        internal data class StringCharacterCounterBuilder(

        ) {
            companion object {
                fun buildBlock(vararg strings: String): List<Int> {
                    return strings.map({ it.length })
                }
            }
        }

        internal open class CharacterCounter {
            val counterArray: List<Int>

            constructor(content: () -> List<Int>) {
                counterArray = content()
            }

            open fun showCounts() {
                counterArray.forEach({ println(it) })
            }
        }

        internal val characterCounts: CharacterCounter = CharacterCounter {
                "Andy"

                // this outputs uncompilable Kotlin
                "Ibanez"

                // (no commas between elements)
                "Collects Pullip"
            }

        characterCounts.counterArray
        """
        }
    }

    func testGenerateCompose() throws {
        try check(swift: 0, kotlin: 0) { _ in
            class ComposeHarness {
                struct Message : Hashable, Codable {
                    let author, body: String
                }

                //@Composable
                func MessageCard(msg: Message) {
                    Text(text: msg.author)
                    Text(text: msg.body)
                }

                // no-op compose stubs
                func Text(text: String) -> Void { }
            }

            return 0
        } verify: {
        """
        internal open class ComposeHarness {
            data class Message(
                val author: String,
                val body: String
            )

            //@Composable
            open fun MessageCard(msg: Message) {
                Text(text = msg.author)
                Text(text = msg.body)
            }

            // no-op compose stubs
            open fun Text(text: String) {
            }
        }

        0
        """
        }
    }

    func testCrossPlatformTmpDir() throws {
        let tmpdir = NSTemporaryDirectory()
        #if os(Linux)
        let jtmpdir = tmpdir.trimmingTrailingCharacters(in: CharacterSet(["/"]))
        #else
        let jtmpdir = tmpdir
        #endif
        try check(autoport: true, swift: String?.some(tmpdir), java: jtmpdir, kotlin: .str(jtmpdir)) { jvm in
            func tmpdir() throws -> String? {
                jvm ? try java$lang$System.getProperty(java$lang$String("java.io.tmpdir"))?.toSwiftString() : /* gryphon value: null */ NSTemporaryDirectory()
            }

            return try tmpdir()
        } verify: {
        """
        fun tmpdir(): String? = if (jvm) { java.lang.System.getProperty(("java.io.tmpdir")) } else { null }

        tmpdir()
        """
        }
    }

    func testCrossPlatformRandom() throws {
        try check(autoport: true, swift: true, java: true, kotlin: .bol(true)) { jvm in

            func generateRandomNumber() throws -> Int64 {
                if jvm {
                    return try java$util$Random().nextLong()
                } else {
                    return /* gryphon value: 0 */ Int64.random(in: (.min)...(.max))
                }
            }

            return try generateRandomNumber() != generateRandomNumber()
        } verify: {
        """
        fun generateRandomNumber(): Long {
            if (jvm) {
                return java.util.Random().nextLong()
            }
            else {
                return 0
            }
        }

        generateRandomNumber() != generateRandomNumber()
        """
        }
    }

    func testGeneratePod() throws {
        XCTAssertTrue(try JavaFileSystemPod().exists(at: "/dev/null"))
        XCTAssertTrue(try SwiftFileSystemPod().exists(at: "/dev/null"))

        XCTAssertFalse(try JavaFileSystemPod().exists(at: "/etc/NOT_A_FILE"))
        XCTAssertFalse(try SwiftFileSystemPod().exists(at: "/etc/NOT_A_FILE"))

        // Must be top-level, or else: Protocol 'FileSystemPod' cannot be nested inside another declaration
        let preamble = FileSystemPodBlockStart..<FileSystemPodBlockEnd
        try check(compile: true, autoport: true, swift: true, java: true, kotlin: .bol(true), preamble: preamble) { jvm in
            try fileSystem(jvm: jvm).exists(at: "/etc/hosts")
        } verify: {
        """
        interface FileSystemPod {
            fun exists(path: String): Boolean
        }

        fun fileSystem(jvm: Boolean): FileSystemPod = if (jvm) { JavaFileSystemPod() } else { JavaFileSystemPod() }

        internal data class JavaFileSystemPod(
            private val x: Boolean = false
        ): FileSystemPod {
            override fun exists(path: String): Boolean = java.io.File((path)).exists() == true
        }

        fileSystem(jvm = jvm).exists(path = "/etc/hosts")
        """
        }

    }

    /// Parse the source file for the given Swift code, translate it into Kotlin, interpret it in the embedded ``KotlinContext``, and compare the result to the Swift result.
    @discardableResult func check<T : Equatable>(compile: Bool = true, autoport: Bool = false, swift: T, java: T? = nil, kotlin: JSum, preamble: Range<Int>? = nil, file: StaticString = #file, line: UInt = #line, block: (Bool) throws -> T, verify: () -> String?) throws -> JSum? {
        let (k, jf) = try transpile(autoport: autoport, preamble: preamble, file: file, line: line)
        let k1 = (k.hasPrefix("internal val jvm: Boolean = true") ? String(k.dropFirst(32)) : k).trimmed()
        if let expected = verify(), expected.trimmed().isEmpty == false {
            XCTAssertEqual(expected.trimmed(), k1.trimmed(), "Expected source disagreed", file: file, line: line)
            if expected.trimmed() != k1.trimmed() {
                return .nul
            }
        } else {
            print("### fill in Kotlin expectation test case:###\n", k1)
        }

        let result = try block(false)
        XCTAssertEqual(result, swift, "Swift values disagreed", file: file, line: line)

        // also execute the block in Java mode
        if let java = java {
            let result = try block(true)
            XCTAssertEqual(result, java, "Java values disagreed", file: file, line: line)
        }

        if compile {
            let j = try jf()
            XCTAssertEqual(j, kotlin, "Kotlin values disagreed", file: file, line: line)
            return j
        } else {
            return nil
        }
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
        return code
    }

    /// Takes the block of code in the source file after the calling line and before the next token (default, `"} verify: {"`), and converts it to Kotlin, executes it in an embedded JVM, and returns the serialized result as a ``JSum``.
    func skiff(token: String = "} verify: {", autoport: Bool, preamble: Range<Int>?, file: StaticString = #file, line: UInt = #line) throws -> (source: String, result: JSum) {
        let result = try transpile(token: token, autoport: autoport, preamble: preamble, file: file, line: line)
        return (result.source, try result.eval())
    }

    func transpile(token: String = "} verify: {", autoport: Bool, preamble: Range<Int>?, file: StaticString = #file, line: UInt = #line) throws -> (source: String, eval: () throws -> (JSum)) {
        let code = try String(contentsOf: URL(fileURLWithPath: file.description))
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map({ String($0) })
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

        var parts = ["let jvm = true"] // when running in Kotlin mode, jvm is always true

        // insert the preamble if we have specified it
        if let preamble = preamble {
            parts += lines[(preamble.startIndex)..<(preamble.endIndex-1)]
        }

        parts += initial[..<brace]

        parts = parts.map {
            $0.replacingOccurrences(of: "return /* noreturn */", with: "") // trim out returns that Kotlin forbids at the top level
        }

        // also check for a return on the final line, which we automatically trim
        if parts.last?.trimmed().hasPrefix("return ") == true {
            parts[parts.endIndex-1] = String(parts[parts.endIndex-1].trimmed().dropFirst(7))
        }
        let swift = parts.joined(separator: "\n")

        //print("swift:", swift.trimmingCharacters(in: .whitespacesAndNewlines))

        var kotlin = try translate(swift: swift) // + (hasReturn ? "()" : "")

        //print("kotlin:", kotlin.trimmingCharacters(in: .whitespacesAndNewlines))


        if autoport {
            // ERROR Type mismatch: inferred type is kotlin.String! but java.lang.String? was expected (ScriptingHost54e041a4_Line_1.kts:1:37)
            kotlin = kotlin.replacingOccurrences(of: "java$lang$String(", with: "(") // fix unnecessary constructor
            // kotlin = kotlin.replacingOccurrences(of: "java$lang$String(", with: "kotlin.String(") // fix unnecessary constructor
            kotlin = kotlin.replacingOccurrences(of: "?.toSwiftString()", with: "") // remove Java string return coercions

            //kotlin = kotlin.replacingOccurrences(of: ".javaString", with: "") // string conversions don't need to be explicit

            // e.g., convert java$lang$String to java.lang.String
            // TODO: make less fragile!
            kotlin = kotlin.replacingOccurrences(of: "$", with: ".")

            // failed: caught error: "ERROR Modifier 'internal' is not applicable to 'local function' (ScriptingHost54e041a4_Line_0.kts:12:1)"
            kotlin = kotlin.replacingOccurrences(of: "internal fun ", with: "fun ")
        }


        if let match = match {
            XCTAssertEqual(match.trimmingCharacters(in: .whitespacesAndNewlines), kotlin.trimmingCharacters(in: .whitespacesAndNewlines), "expected transpiled Kotlin mismatch", file: file, line: line)
        }
        return (kotlin, { try self.ctx.eval(.val(.str(kotlin))).jsum() })
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

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}





// inline translation elsewhere in the file, since protocols cannot be nested inside anything
let FileSystemPodBlockStart = #line

public protocol FileSystemPod {
    func exists(at path: String) throws -> Bool
}

/// Returns either the Java or Swift implementation of the ``FileSystemPod``
func fileSystem(jvm: Bool) -> FileSystemPod {
    jvm ? JavaFileSystemPod() : /* gryphon value: JavaFileSystemPod() */ SwiftFileSystemPod()
}

// gryphon ignore
struct SwiftFileSystemPod : FileSystemPod {
    func exists(at path: String) throws -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

struct JavaFileSystemPod : FileSystemPod {
    private let x: Bool = false

    // gryphon annotation: override
    func exists(at path: String) throws -> Bool {
        try java$io$File(java$lang$String(path)).exists() == true
    }
}

let FileSystemPodBlockEnd = #line


