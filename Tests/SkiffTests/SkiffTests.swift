import XCTest
@testable import Skiff
import KotlinKanji
import JavaLib
import GryphonLib
import JSum

final class SkiffTests: XCTestCase {
    static let skiff = Result { try Skiff() }

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

    func testPreprocessorRandom() throws {
        try check(autoport: true, swift: true, java: true, kotlin: .bol(true)) { jvm in

            func generateRandomNumber() throws -> Int64 {
                #if KOTLIN
                return java.util.Random().nextLong()
                #else
                return Int64.random(in: (.min)...(.max))
                #endif
            }

            return try generateRandomNumber() != generateRandomNumber()
        } verify: {
        """
         fun generateRandomNumber(): Long {
            return java.util.Random().nextLong()
        }

        generateRandomNumber() != generateRandomNumber()
        """
        }
    }

    func testGeneratePod() throws {
        XCTAssertTrue(try JavaFileSystemModule().exists(at: "/dev/null"))
        XCTAssertTrue(try SwiftFileSystemModule().exists(at: "/dev/null"))

        XCTAssertFalse(try JavaFileSystemModule().exists(at: "/etc/NOT_A_FILE"))
        XCTAssertFalse(try SwiftFileSystemModule().exists(at: "/etc/NOT_A_FILE"))

        // Must be top-level, or else: Protocol 'FileSystemModule' cannot be nested inside another declaration
        let preamble = FileSystemModuleBlockStart..<FileSystemModuleBlockEnd
        try check(compile: true, autoport: true, swift: true, java: true, kotlin: .bol(true), preamble: preamble) { jvm in
            try fileSystem(jvm: jvm).exists(at: "/etc/hosts")
        } verify: {
        """
        interface FileSystemModule {
            fun exists(path: String): Boolean
        }

        fun fileSystem(jvm: Boolean): FileSystemModule = if (jvm) { JavaFileSystemModule() } else { JavaFileSystemModule() }

        internal data class JavaFileSystemModule(
            private val x: Boolean = false
        ): FileSystemModule {
            override fun exists(path: String): Boolean = java.io.File((path)).exists() == true
        }

        fileSystem(jvm = jvm).exists(path = "/etc/hosts")
        """
        }

    }

    /// Parse the source file for the given Swift code, translate it into Kotlin, interpret it in the embedded ``KotlinContext``, and compare the result to the Swift result.
    @discardableResult func check<T : Equatable>(compile: Bool = true, autoport: Bool = false, swift: T, java: T? = nil, kotlin: JSum, preamble: Range<Int>? = nil, file: StaticString = #file, line: UInt = #line, block: (Bool) throws -> T, verify: () -> String?) throws -> JSum? {
        let (k, jf) = try Self.skiff.get().transpile(autoport: autoport, preamble: preamble, file: file, line: line)
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

    func testAsyncFunctionsNotTranslated() throws {
        try check(autoport: true, swift: true, java: true, kotlin: true) { jvm in
            func asyncFunc() async throws -> String {
                ""
            }

            return true
        } verify: {
        """
        fun asyncFunc(): String = ""

        true
        """
        }

        // SkiffTests.swift:465: error: -[SkiffTests.SkiffTests testAsyncFunctionsNotTranslated] : failed: caught error: ":3:21: error: Unknown expression (failed to translate SwiftSyntax node).

//        try check(compile: false, autoport: true, swift: true, java: true, kotlin: true) { jvm in
//            func asyncFunc(url: URL) async throws -> Data {
//                try await URLSession.shared.data(for: URLRequest(url: url)).0
//            }
//
//            return true
//        } verify: {
//        """
//        fun asyncFunc(): String = ""
//
//        true
//        """
//        }

    }

    func compare(swift: String, kotlin: String, file: StaticString = #file, line: UInt = #line) throws {
        XCTAssertEqual(kotlin.trimmed(), try Self.skiff.get().translate(swift: swift, file: file, line: line).trimmed(), file: file, line: line)
    }


    /// Run a few simple simple Kotlin snippets and check their output
    func testKotlinSnippets() throws {
        let ctx = try Self.skiff.get().context
        XCTAssertEqual(3, try ctx.eval("1+2").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 'a'; 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 'a'; 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ val x = 3; x }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ val x = 2; var y = 1; x + y; }()").jsum())
        //XCTAssertEqual(3, try ctx.eval("return 1+2").jsum())
        //XCTAssertEqual(3, try ctx.eval("{ val x = 1+2; return x }()").jsum())
    }

    func testReplaceCaptures() throws {
        do {
            XCTAssertEqual("""
            func getLine() -> String {
                var line1 = ""
                // this is some raw Kotlin
                val line2 = someKotlin()
                return line1 + line2
            }
            """, try Self.skiff.get().processKotlinBlock(code: """
            func getLine() -> String {
                var line1 = ""
                #if KOTLIN
                // this is some raw Kotlin
                val line2 = someKotlin()
                #else
                // this is some raw Swift
                let line2 = someSwift()
                #endif
                return line1 + line2
            }
            """))

        }
    }


}



// inline translation elsewhere in the file, since protocols cannot be nested inside anything
let FileSystemModuleBlockStart = #line

public protocol FileSystemModule {
    func exists(at path: String) throws -> Bool
}

/// Returns either the Java or Swift implementation of the ``FileSystemModule``
func fileSystem(jvm: Bool) -> FileSystemModule {
    jvm ? JavaFileSystemModule() : /* gryphon value: JavaFileSystemModule() */ SwiftFileSystemModule()
}

// gryphon ignore
struct SwiftFileSystemModule : FileSystemModule {
    func exists(at path: String) throws -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

struct JavaFileSystemModule : FileSystemModule {
    private let x: Bool = false

    // gryphon annotation: override
    func exists(at path: String) throws -> Bool {
        try java$io$File(java$lang$String(path)).exists() == true
    }
}

let FileSystemModuleBlockEnd = #line


