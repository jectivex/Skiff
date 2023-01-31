import Foundation

/// A container for a Swift-to-Kotlin translation context.
public struct Skiff {
    public init() {

    }
    
    public enum TranslateError : Error {
        case noResult
        case noInitialResult
        case noInitialTranslationResult
    }
}


extension String {
    public func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The total span of this string expressed as an NSRange
    var span: NSRange {
        NSRange(startIndex..<endIndex, in: self)
    }

    public func replacing(expression: NSRegularExpression, options: NSRegularExpression.MatchingOptions = [], captureGroups: [String], replacing: (_ captureGroupName: String, _ captureGroupValue: String) throws -> String?) rethrows -> String {
        var str = self
        for match in expression.matches(in: self, options: options, range: self.span).reversed() {
            for valueName in captureGroups {
                let textRange = match.range(withName: valueName)
                if textRange.location == NSNotFound {
                    continue
                }
                let existingValue = (self as NSString).substring(with: textRange)

                //dbg("replacing header range:", match.range, " with bold text:", text)
                if let newValue = try replacing(valueName, existingValue) {
                    str = (str as NSString).replacingCharacters(in: match.range, with: newValue)
                }
            }
        }
        return str
    }
}

#if canImport(GryphonLib)
import GryphonLib

extension Skiff {
    public func transpileInline(token: String = "} verify: {", options: TranslationOptions, preamble: Range<Int>?, file: StaticString = #file, line: UInt = #line) throws -> (swift: String, kotlin: String) {
        let code = try String(contentsOf: URL(fileURLWithPath: file.description))
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map({ String($0) })
        let initial = Array(lines[.init(line)...])
        guard let brace = initial.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(token) }) else {
            struct UnableToFindMatchingVerifyBlock : Error {
            }
            throw UnableToFindMatchingVerifyBlock()
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

        let kotlin = try translate(swift: swift, moduleName: nil, options: options) // + (hasReturn ? "()" : "")
        return (swift, kotlin)
    }

    /// Takes code with `#if KOTLIN … #else … #endif` or `#if os(Android) … #else … #endif` and returns just the Kotlin code.
    func processKotlinBlock(code: String, gryphonBlocks: Set<String> = ["SKIP", "KOTLIN", "os\\(Android\\)"]) throws -> String {
        var code = code

        // we could translate #if KOTLIN to #if GRYPHON, but the Gryphon preprocessor block doesn't work for some nesting scenarios, so we merely regex-out the blocks instead

//        if !gryphonBlocks.isEmpty {
//            for token in gryphonBlocks {
//                code = code.replacingOccurrences(of: "#if \(token)", with: "#if GRYPHON")
//            }
//            return code
//        }

        for token in gryphonBlocks {
            /// handle `#if KOTLIN … #else … #endif`
            let ifElseBlock = try NSRegularExpression(pattern: "\n *#if \(token) *\n(?<KOTLIN>[^#]*)\n *#else *\n(?<SWIFT>[^#]*)\n *#endif", options: [.dotMatchesLineSeparators])
            /// handle `#if KOTLIN … #endif`
//            let ifBlock = try NSRegularExpression(pattern: "\n *#if \(token) *\n(?<KOTLIN>.*)\n *#endif", options: [.dotMatchesLineSeparators])


            code = code
                .replacing(expression: ifElseBlock, captureGroups: ["KOTLIN", "SWIFT"], replacing: { paramName, paramValue in
                    paramName == "KOTLIN" ? "\n" + paramValue : nil
                })
//                .replacing(expression: ifBlock, captureGroups: ["KOTLIN"], replacing: { paramName, paramValue in
//                    paramName == "KOTLIN" ? "\n" + paramValue : nil
//                })
        }

        return code
    }

    public struct TranslationOptions : OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let autoport = Self(rawValue: 1<<0)
        public static let testCase = Self(rawValue: 1<<1)
    }

    public func translate(swift: String, moduleName: String?, options: TranslationOptions = [], file: StaticString = #file, line: UInt = #line) throws -> String {
        var swift = swift
        // error: Unsupported #if declaration; only `#if GRYPHON`, `#if !GRYPHON` and `#else` are supported (failed to translate SwiftSyntax node).
        swift = swift.replacingOccurrences(of: "#if canImport(Skiff)", with: "#if GRYPHON")

        // also swap out #if KOTLIN blocks
        swift = try processKotlinBlock(code: swift)

        //print("### swift:", swift)

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

        var kotlin = translation.kotlinCode

        //print("kotlin:", kotlin.trimmingCharacters(in: .whitespacesAndNewlines))


        func replace(_ string: String, with replacement: String) {
            kotlin = kotlin.replacingOccurrences(of: string, with: replacement)
        }

        // fixed an issue with the top-level functions:
        // failed: caught error: "ERROR Modifier 'internal' is not applicable to 'local function' (ScriptingHost54e041a4_Line_0.kts:12:1)"
        replace("internal fun ", with: "fun ")

        // replace("convenience constructor", with: "constructor") // Gryphon bug // construtor delegation doesn't work

        replace(": RawRepresentable()", with: "")
        replace("@JvmInline\n\ndata class", with: "@JvmInline value class")


        if options.contains(.autoport) {
            // include #if KOTLIN pre-processor blocks

            // ERROR Type mismatch: inferred type is kotlin.String! but java.lang.String? was expected (ScriptingHost54e041a4_Line_1.kts:1:37)
            replace("java$lang$String(", with: "(") // fix unnecessary constructor
            // replace("java$lang$String(", with: "kotlin.String(") // fix unnecessary constructor
            replace("?.toSwiftString()", with: "") // remove Java string return coercions

            //replace(".javaString", with: "") // string conversions don't need to be explicit

            // e.g., convert java$lang$String to java.lang.String
            for package in [
                "java$lang$",
                "java$io$",
                "java$util$",
            ] {
                let dotsInsteadOfDollars = package.replacingOccurrences(of: "$", with: ".")
                replace(package, with: dotsInsteadOfDollars)
            }
        }

        // convert XCTest to a JUnit test runner
        if options.contains(.testCase) {
            // replace common XCTest assertions with their JUnit equivalent
            let testCaseShims = """

            // Mimics the API of XCTest for a JUnit test
            // Behavior difference: JUnit assert* thows an exception, but XCTAssert* just reports the failure and continues

            private interface XCTestCase {
                fun XCTFail() = Assert.fail()

                fun XCTFail(msg: String) = Assert.fail(msg)

                fun XCTUnwrap(ob: Any?) = { Assert.assertNotNull(ob); ob }
                fun XCTUnwrap(ob: Any?, msg: String) = { Assert.assertNotNull(msg, ob); ob }

                fun XCTAssertTrue(a: Boolean) = Assert.assertTrue(a as Boolean)
                fun XCTAssertTrue(a: Boolean, msg: String) = Assert.assertTrue(msg, a)
                fun XCTAssertFalse(a: Boolean) = Assert.assertFalse(a)
                fun XCTAssertFalse(a: Boolean, msg: String) = Assert.assertFalse(msg, a)

                fun XCTAssertNil(a: Any?) = Assert.assertNull(a)
                fun XCTAssertNil(a: Any?, msg: String) = Assert.assertNull(msg, a)
                fun XCTAssertNotNil(a: Any?) = Assert.assertNotNull(a)
                fun XCTAssertNotNil(a: Any?, msg: String) = Assert.assertNotNull(msg, a)

                fun XCTAssertIdentical(a: Any?, b: Any?) = Assert.assertSame(a, b)
                fun XCTAssertIdentical(a: Any?, b: Any?, msg: String) = Assert.assertSame(msg, a, b)
                fun XCTAssertNotIdentical(a: Any?, b: Any?) = Assert.assertNotSame(a, b)
                fun XCTAssertNotIdentical(a: Any?, b: Any?, msg: String) = Assert.assertNotSame(msg, a, b)

                fun XCTAssertEqual(a: Any?, b: Any?) = Assert.assertEquals(a, b)
                fun XCTAssertEqual(a: Any?, b: Any?, msg: String) = Assert.assertEquals(msg, a, b)
                fun XCTAssertNotEqual(a: Any?, b: Any?) = Assert.assertNotEquals(a, b)
                fun XCTAssertNotEqual(a: Any?, b: Any?, msg: String) = Assert.assertNotEquals(msg, a, b)

                // additional overloads needed for XCTAssert*() which have different signatures on Linux (@autoclosures) than on Darwin platforms (direct values)

                fun XCTUnwrap(ob: () -> Any?) = { val x = ob(); Assert.assertNotNull(x); x }
                fun XCTUnwrap(ob: () -> Any?, msg: () -> String) = { val x = ob(); Assert.assertNotNull(msg(), x); x }

                fun XCTAssertTrue(a: () -> Boolean) = Assert.assertTrue(a())
                fun XCTAssertTrue(a: () -> Boolean, msg: () -> String) = Assert.assertTrue(msg(), a())
                fun XCTAssertFalse(a: () -> Boolean) = Assert.assertFalse(a())
                fun XCTAssertFalse(a: () -> Boolean, msg: () -> String) = Assert.assertFalse(msg(), a())

                fun XCTAssertNil(a: () -> Any?) = Assert.assertNull(a())
                fun XCTAssertNil(a: () -> Any?, msg: () -> String) = Assert.assertNull(msg(), a())
                fun XCTAssertNotNil(a: () -> Any?) = Assert.assertNotNull(a())
                fun XCTAssertNotNil(a: () -> Any?, msg: () -> String) = Assert.assertNotNull(msg(), a())

                fun XCTAssertIdentical(a: () -> Any?, b: () -> Any?) = Assert.assertSame(a(), b())
                fun XCTAssertIdentical(a: () -> Any?, b: () -> Any?, msg: () -> String) = Assert.assertSame(msg(), a(), b())
                fun XCTAssertNotIdentical(a: () -> Any?, b: () -> Any?) = Assert.assertNotSame(a(), b())
                fun XCTAssertNotIdentical(a: () -> Any?, b: () -> Any?, msg: () -> String) = Assert.assertNotSame(msg(), a(), b())

                fun XCTAssertEqual(a: () -> Any?, b: () -> Any?) = Assert.assertEquals(a(), b())
                fun XCTAssertEqual(a: () -> Any?, b: () -> Any?, msg: () -> String) = Assert.assertEquals(msg(), a(), b())
                fun XCTAssertNotEqual(a: () -> Any?, b: () -> Any?) = Assert.assertNotEquals(a(), b())
                fun XCTAssertNotEqual(a: () -> Any?, b: () -> Any?, msg: () -> String) = Assert.assertNotEquals(msg(), a(), b())
            }


            """

            replace("internal fun ", with: "fun ")
            replace("open fun test", with: "@Test fun test") // any functions prefixed with "test" will get the JUnit @Test annotation

            // add the test runner to the top
            replace("internal class", with: """
            import kotlin.test.*
            import org.junit.Test
            import org.junit.Assert
            import org.junit.runner.RunWith

            import kotlinx.coroutines.*
            import kotlinx.coroutines.test.*

            @RunWith(org.robolectric.RobolectricTestRunner::class)
            @org.robolectric.annotation.Config(manifest=org.robolectric.annotation.Config.NONE)
            internal class
            """)

            kotlin += "\n\n"
            kotlin += testCaseShims
        }

        if let moduleName = moduleName {
            kotlin = """
            // =========================================
            // GENERATED FILE; EDITS WILL BE OVERWRITTEN
            // =========================================
            package \(moduleName)

            """ + kotlin
        }


        return kotlin
    }

    #if os(macOS) || os(Linux)
    /// Forks a gradle process for the given projects. Assumes that `gradle` is somewhere in the PATH.
    public func gradle(project projectPath: String, actions: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh", isDirectory: false)
        var args: [String] = ["-c"]

        args += [
            "ANDROID_HOME=" + (("~/Library/Android/sdk" as NSString).expandingTildeInPath), // otherwise: “SDK location not found. Define a valid SDK location with an ANDROID_HOME environment variable or by setting the sdk.dir path in your project's local properties file”
            "GRADLE_OPTS=-Xmx512m", // otherwise: “To honour the JVM settings for this build a single-use Daemon process will be forked.”
            ]

        args += ["gradle"] + actions
        args += [
            //"--no-daemon",
            "--console", "plain",
            "--info",
            //"--stacktrace",
            "--rerun-tasks", // re-run tests
            "--project-dir", projectPath,
        ]

        process.arguments = args

        process.launch()
        process.waitUntilExit()

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            // TODO: read the standard output and translate some common failures into an error enum
            struct ChildTaskFailed : Error {
                let exitCode: Int32
            }

            throw ChildTaskFailed(exitCode: exitCode)
        }
    }

    public func transpileAndTest(file: String = #file) throws {
        let testSourceURL = URL(fileURLWithPath: file, isDirectory: false)
        let testBase = testSourceURL
            .deletingLastPathComponent()
        let projectRoot = testBase
            .deletingLastPathComponent()
            .deletingLastPathComponent()


        let sourcesFolderName = "Sources"
        let testsFolderName = "Tests"

        let fileFolderName = testBase.lastPathComponent
        if !fileFolderName.hasSuffix(testsFolderName) {
            struct SourceFileExpectedInTestsFolder : Error { }
            throw SourceFileExpectedInTestsFolder()
        }

        let moduleName = String(fileFolderName.dropLast(5))
        print("### building module:", moduleName)

        for sourceRoot in [sourcesFolderName, testsFolderName] {
            let isTest = sourceRoot == testsFolderName
            let sourceBase = URL(fileURLWithPath: sourceRoot, isDirectory: true, relativeTo: projectRoot)

            // deep scan for .swift files
            for sourceURL in (FileManager.default.enumerator(at: sourceBase, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL]) ?? [] {
//            for sourceURL in try FileManager.default.contentsOfDirectory(at: sourceBase, includingPropertiesForKeys: [.isDirectoryKey]) {

                if sourceURL.pathExtension != "swift" {
                    continue // we only look at swift files for transpilation
                }
                let kotlinURL = sourceURL.deletingPathExtension().appendingPathExtension("kt")

                let source = try String(contentsOf: sourceURL)

                //print("### translating:", sourceURL.path, "to:", kotlinURL.path)
                let kotlin = try self.translate(swift: source, moduleName: moduleName, options: isTest ? [.testCase] : [])
                try kotlin.write(to: kotlinURL, atomically: true, encoding: .utf8)
            }
        }

        var actions: [String] = []
        #if DEBUG
        actions = ["testDebugUnitTest"]
        #else
        actions = ["testReleaseUnitTest"]
        #endif

        //actions = ["cleanTest"] + actions // cleanTest needs to be run or else the tests won't be re-run

        try gradle(project: projectRoot.path, actions: actions)

    }
    #endif
}
#endif

