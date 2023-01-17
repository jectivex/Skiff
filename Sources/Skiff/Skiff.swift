import Foundation
import JSum
import KotlinKanji
import GryphonLib

/// A container for a Swift-to-Kotlin translation context.
public class Skiff {
    let context: KotlinContext

    public init() throws {
        self.context = try KotlinContext()
    }

    public enum TranslateError : Error {
        case noResult
        case noInitialResult
        case noInitialTranslationResult
    }


    public func translate(swift: String, autoport: Bool = false, file: StaticString = #file, line: UInt = #line) throws -> String {
        var swift = swift
        if autoport {
            // error: Unsupported #if declaration; only `#if GRYPHON`, `#if !GRYPHON` and `#else` are supported (failed to translate SwiftSyntax node).
            swift = swift.replacingOccurrences(of: "#if canImport(Skiff)", with: "#if GRYPHON")

            // also swap out #if KOTLIN blocks
            swift = try processKotlinBlock(code: swift)
        }

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


        if autoport {
            // include #if KOTLIN pre-processor blocks

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
        
        return kotlin
    }

    /// Takes the block of code in the source file after the calling line and before the next token (default, `"} verify: {"`), and converts it to Kotlin, executes it in an embedded JVM, and returns the serialized result as a ``JSum``.
    public func skiff(token: String = "} verify: {", autoport: Bool, preamble: Range<Int>?, file: StaticString = #file, line: UInt = #line) throws -> (source: String, result: JSum) {
        let result = try transpile(token: token, autoport: autoport, preamble: preamble, file: file, line: line)
        return (result.source, try result.eval())
    }

    public func transpile(token: String = "} verify: {", autoport: Bool, preamble: Range<Int>?, file: StaticString = #file, line: UInt = #line) throws -> (source: String, eval: () throws -> (JSum)) {
        let code = try String(contentsOf: URL(fileURLWithPath: file.description))
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map({ String($0) })
        let initial = Array(lines[.init(line)...])
        guard let brace = initial.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(token) }) else {
            throw CocoaError(.formatting)
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

        let kotlin = try translate(swift: swift, autoport: autoport) // + (hasReturn ? "()" : "")
        return (kotlin, { try self.context.eval(.val(.str(kotlin))).jsum() })
    }

    /// Takes code with `#if KOTLIN … #else … #endif` and returns just the Kotlin code.
    func processKotlinBlock(code: String) throws -> String {
        let exp = try NSRegularExpression(pattern: "\n *#if KOTLIN *\n(?<KOTLIN>.*)\n *#else *\n(?<SWIFT>.*)\n *#endif", options: [.dotMatchesLineSeparators])
        return code.replacing(expression: exp, captureGroups: ["KOTLIN", "SWIFT"], replacing: { paramName, paramValue in
            paramName == "KOTLIN" ? "\n" + paramValue : nil // only return the Kotlin pre-processed blocks
        })
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
