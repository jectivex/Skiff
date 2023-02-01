import XCTest
import SymbolKit
@testable import Skiff

#if canImport(GryphonLib)
import GryphonLib
import KotlinKanji
import JavaLib
import JSum

final class SkiffTests: XCTestCase {
    /// A shared skiff context for evaluating transpiled results
    static let skiff = Result { try SkiffContext() }

    class SkiffContext {
        let skiff: Skiff
        let context: KotlinContext

        public init(skiff: Skiff = Skiff()) throws {
            self.skiff = skiff
            self.context = try KotlinContext()
        }

        public func transpileInline(autoport: Bool, preamble: Range<Int>?, file: StaticString = #file, line: UInt = #line) throws -> (swift: String, kotlin: String, eval: () throws -> (JSum)) {
            let source = try skiff.transpileInline(options: autoport ? [.autoport] : [], preamble: preamble, file: file, line: line)
            return (source.swift, source.kotlin, { try self.context.eval(.val(.str(source.kotlin))).jsum() })
        }
    }

    /// Parse the source file for the given Swift code, translate it into Kotlin, interpret it in the embedded ``KotlinContext``, and compare the result to the Swift result.
    @discardableResult func check<T : Equatable>(compile: Bool? = nil, autoport: Bool = false, swift: T, java: T? = nil, kotlin: JSum? = .none, preamble: Range<Int>? = nil, file: StaticString = #file, line: UInt = #line, block: (Bool) async throws -> T, verify: () -> String?, symbols: () -> SymbolGraph? = { nil }) async throws -> JSum? {
        let (s, k, jf) = try Self.skiff.get().transpileInline(autoport: autoport, preamble: preamble, file: file, line: line)

        if let symbols = symbols() {
            try compareSymbols(swift: s, symbols: symbols, file: file, line: line)
        }

        let k1 = (k.hasPrefix("internal val jvm: Boolean = true") ? String(k.dropFirst(32)) : k).trimmed()
        if let expected = verify(), expected.trimmed().isEmpty == false {
            XCTAssertEqual(expected.trimmed(), k1.trimmed(), "Expected source disagreed", file: file, line: line)
            if expected.trimmed() != k1.trimmed() {
                return .nul
            }
        } else {
            print("### fill in Kotlin expectation test case:###\n", k1)
        }

        let result = try await block(false)
        XCTAssertEqual(result, swift, "Swift values disagreed", file: file, line: line)

        // also execute the block in Java mode
        if let java = java {
            let result = try await block(true)
            XCTAssertEqual(result, java, "Java values disagreed", file: file, line: line)
        }

        if compile != false, let kotlin = kotlin {
            let j = try jf()
            XCTAssertEqual(j, kotlin, "Kotlin values disagreed", file: file, line: line)
            return j
        } else {
            return nil
        }
    }

    func testParsedSymbols() throws {
        try compareSymbols(swift: """
        import Foundation

        /// Doc comments are matched to their types
        struct Basic : Equatable {
            let int: Int? = nil
            let str: String = "abc"
            /// a double property
            let dbl: Double

            let int2 = 1
            let str2 = "qrs"
            let dbl2 = 1.1

            let nul = NSNull()

            let nestedStruct = NestedStruct()

            struct NestedStruct : Hashable, Codable {
                var nestedField: String?
            }
        }
        """) { graph in
            let allSymbols = graph.symbols.values

            dump(graph.relationships, name: "relationships")

            // get a consistent ordering (we might prefer by source line number?)
            let symbolsInOrder = allSymbols.sorted {
                $0.identifier.precise < $1.identifier.precise
            }

            XCTAssertEqual(symbolsInOrder.map(\.pathComponents), [
                ["Basic"],
                ["Basic", "NestedStruct"],
                ["Basic", "NestedStruct", "init(nestedField:)"],
                ["Basic", "NestedStruct", "nestedField"],
                ["Basic", "NestedStruct", "init(from:)"],
                ["Basic", "NestedStruct", "init()"],
                ["Basic", "nestedStruct"],
                ["Basic", "init(dbl:)"],
                ["Basic", "dbl"],
                ["Basic", "int"],
                ["Basic", "nul"],
                ["Basic", "str"],
                ["Basic", "dbl2"],
                ["Basic", "int2"],
                ["Basic", "str2"],
                ["Basic", "!=(_:_:)"],
                ["Basic", "NestedStruct", "!=(_:_:)"],
            ])


            let basic = try XCTUnwrap(allSymbols.first(where: { $0.pathComponents == ["Basic"] }))
            XCTAssertEqual(.struct, basic.kind.identifier)
            XCTAssertEqual(.init(rawValue: "internal"), basic.accessLevel)
            XCTAssertEqual(nil, basic.type)
            XCTAssertEqual("Basic", basic.names.subHeading?.last?.spelling)
            XCTAssertEqual("Doc comments are matched to their types", basic.docComment?.lines.first?.text)
            XCTAssertEqual(2, basic.docComment?.lines.first?.range?.start.line)

            let location = try XCTUnwrap(basic.mixins["location"] as? SymbolGraph.Symbol.Location)
            XCTAssertEqual(3, location.position.line)

            let declarationFragments = try XCTUnwrap(basic.mixins["declarationFragments"] as? SymbolKit.SymbolGraph.Symbol.DeclarationFragments)
            XCTAssertEqual("Basic", declarationFragments.declarationFragments.last?.spelling)

            // Basic conforms to Equatable
            XCTAssertNotNil(graph.relationships.first(where: { $0.source == "s:6source5BasicV" && $0.kind == .conformsTo && $0.target == "s:SQ" && $0.targetFallback == "Swift.Equatable" }))

            // Basic.NestedStruct conforms to Equatable and Hashable
            XCTAssertNotNil(graph.relationships.first(where: { $0.source == "s:6source5BasicV12NestedStructV" && $0.kind == .conformsTo && $0.target == "s:SQ" && $0.targetFallback == "Swift.Equatable" }))
            XCTAssertNotNil(graph.relationships.first(where: { $0.source == "s:6source5BasicV12NestedStructV" && $0.kind == .conformsTo && $0.target == "s:SH" && $0.targetFallback == "Swift.Hashable" }))

            dump(basic, name: "basic")

            let symFromName = { name in try XCTUnwrap(allSymbols.first(where: { $0.pathComponents == ["Basic", name] })) }

            let dbl = try symFromName("dbl")
            XCTAssertEqual(.property, dbl.kind.identifier)
            XCTAssertEqual(.init(rawValue: "internal"), dbl.accessLevel)
            XCTAssertEqual(nil, dbl.type) // we'd like "Double" here…
            XCTAssertEqual("Double", dbl.names.subHeading?.last?.spelling)
            XCTAssertEqual("a double property", dbl.docComment?.lines.first?.text)
            dump(dbl, name: "dbl")

            let int = try symFromName("int")
            XCTAssertEqual(.property, int.kind.identifier)
            XCTAssertEqual(.init(rawValue: "internal"), int.accessLevel)
            XCTAssertEqual(nil, int.type)
            XCTAssertEqual("?", int.names.subHeading?.last?.spelling)
            XCTAssertEqual(nil, int.names.subHeading?.last?.preciseIdentifier)
            XCTAssertEqual("Int", int.names.subHeading?.dropLast(1).last?.spelling)
            XCTAssertEqual("s:Si", int.names.subHeading?.dropLast(1).last?.preciseIdentifier)

            dump(int, name: "int")

            let dbl2 = try symFromName("dbl2")
            XCTAssertEqual(.property, dbl2.kind.identifier)
            XCTAssertEqual(.init(rawValue: "internal"), dbl2.accessLevel)
            XCTAssertEqual(nil, dbl2.type)
            XCTAssertEqual("Double", dbl2.names.subHeading?.last?.spelling)
            XCTAssertEqual("s:Sd", dbl2.names.subHeading?.last?.preciseIdentifier)

            dump(dbl2, name: "dbl2")
            // ▿ dbl2: SymbolKit.SymbolGraph.Symbol
            //   ▿ identifier: SymbolKit.SymbolGraph.Symbol.Identifier
            //     - precise: "s:6source5BasicV4dbl2Sdvp"
            //     - interfaceLanguage: "swift"
            //   ▿ kind: SymbolKit.SymbolGraph.Symbol.Kind
            //     ▿ identifier: SymbolKit.SymbolGraph.Symbol.KindIdentifier
            //       - rawValue: "property"
            //     - displayName: "Instance Property"
            //   ▿ pathComponents: 2 elements
            //     - "Basic"
            //     - "dbl2"
            //   - type: nil
            //   ▿ names: SymbolKit.SymbolGraph.Symbol.Names
            //     - title: "dbl2"
            //     - navigator: nil
            //     ▿ subHeading: Optional([SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: // SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "keyword"), spelling: "let", preciseIdentifier: nil), // SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "text"), // spelling: " ", preciseIdentifier: nil), SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: // SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "identifier"), spelling: "dbl2", preciseIdentifier: nil), // SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "text"), // spelling: ": ", preciseIdentifier: nil), SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: // SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "typeIdentifier"), spelling: "Double", preciseIdentifier: // Optional("s:Sd"))])
            //       ▿ some: 5 elements
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "keyword"
            //           - spelling: "let"
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "text"
            //           - spelling: " "
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "identifier"
            //           - spelling: "dbl2"
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "text"
            //           - spelling: ": "
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "typeIdentifier"
            //           - spelling: "Double"
            //           ▿ preciseIdentifier: Optional("s:Sd")
            //             - some: "s:Sd"
            //     - prose: nil
            //   - docComment: nil
            //   - isVirtual: false
            //   ▿ accessLevel: SymbolKit.SymbolGraph.Symbol.AccessControl
            //     - rawValue: "internal"
            //   ▿ mixins: 2 key/value pairs
            //     ▿ (2 elements)
            //       - key: "location"
            //       ▿ value: SymbolKit.SymbolGraph.Symbol.Location
            //         - uri: "file:///var/folders/zl/wkdjv4s1271fbm6w0plzknkh0000gn/T/C0138B09-BA98-4383-98A0-E47AB4228617/source.swift"
            //         ▿ position: SymbolKit.SymbolGraph.LineList.SourceRange.Position
            //           - line: 10
            //           - character: 8
            //     ▿ (2 elements)
            //       - key: "declarationFragments"
            //       ▿ value: SymbolKit.SymbolGraph.Symbol.DeclarationFragments
            //         ▿ declarationFragments: 5 elements
            //           ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //             ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //               - rawValue: "keyword"
            //             - spelling: "let"
            //             - preciseIdentifier: nil
            //           ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //             ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //               - rawValue: "text"
            //             - spelling: " "
            //             - preciseIdentifier: nil
            //           ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //             ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //               - rawValue: "identifier"
            //             - spelling: "dbl2"
            //             - preciseIdentifier: nil
            //           ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //             ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //               - rawValue: "text"
            //             - spelling: ": "
            //             - preciseIdentifier: nil
            //           ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //             ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //               - rawValue: "typeIdentifier"
            //             - spelling: "Double"
            //             ▿ preciseIdentifier: Optional("s:Sd")
            //               - some: "s:Sd"


            let nul = try symFromName("nul")
            XCTAssertEqual(.property, nul.kind.identifier)
            XCTAssertEqual(.init(rawValue: "internal"), nul.accessLevel)
            XCTAssertEqual(nil, nul.type)
            XCTAssertEqual("NSNull", nul.names.subHeading?.last?.spelling)
            #if os(Linux)
            XCTAssertEqual("s:10Foundation6NSNullC", nul.names.subHeading?.last?.preciseIdentifier)
            #else
            XCTAssertEqual("c:objc(cs)NSNull", nul.names.subHeading?.last?.preciseIdentifier)
            #endif

            dump(nul, name: "nul")
            // nul: SymbolKit.SymbolGraph.Symbol
            // ▿ identifier: SymbolKit.SymbolGraph.Symbol.Identifier
            //   - precise: "s:6source5BasicV3nulSo6NSNullCvp"
            //   - interfaceLanguage: "swift"
            // ▿ kind: SymbolKit.SymbolGraph.Symbol.Kind
            //   ▿ identifier: SymbolKit.SymbolGraph.Symbol.KindIdentifier
            //     - rawValue: "property"
            //   - displayName: "Instance Property"
            // ▿ pathComponents: 2 elements
            //   - "Basic"
            //   - "nul"
            // - type: nil
            // ▿ names: SymbolKit.SymbolGraph.Symbol.Names
            //   - title: "nul"
            //   - navigator: nil
            //   ▿ subHeading: Optional([SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "keyword"), spelling: "let", preciseIdentifier: nil), SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "text"), spelling: " ", preciseIdentifier: nil), SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "identifier"), spelling: "nul", preciseIdentifier: nil), SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "text"), spelling: ": ", preciseIdentifier: nil), SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment(kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind(rawValue: "typeIdentifier"), spelling: "NSNull", preciseIdentifier: Optional("c:objc(cs)NSNull"))])
            //     ▿ some: 5 elements
            //       ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //         ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //           - rawValue: "keyword"
            //         - spelling: "let"
            //         - preciseIdentifier: nil
            //       ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //         ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //           - rawValue: "text"
            //         - spelling: " "
            //         - preciseIdentifier: nil
            //       ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //         ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //           - rawValue: "identifier"
            //         - spelling: "nul"
            //         - preciseIdentifier: nil
            //       ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //         ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //           - rawValue: "text"
            //         - spelling: ": "
            //         - preciseIdentifier: nil
            //       ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //         ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //           - rawValue: "typeIdentifier"
            //         - spelling: "NSNull"
            //         ▿ preciseIdentifier: Optional("c:objc(cs)NSNull")
            //           - some: "c:objc(cs)NSNull"
            //   - prose: nil
            // - docComment: nil
            // - isVirtual: false
            // ▿ accessLevel: SymbolKit.SymbolGraph.Symbol.AccessControl
            //   - rawValue: "internal"
            // ▿ mixins: 2 key/value pairs
            //   ▿ (2 elements)
            //     - key: "location"
            //     ▿ value: SymbolKit.SymbolGraph.Symbol.Location
            //       - uri: "file:///var/folders/zl/wkdjv4s1271fbm6w0plzknkh0000gn/T/C0138B09-BA98-4383-98A0-E47AB4228617/source.swift"
            //       ▿ position: SymbolKit.SymbolGraph.LineList.SourceRange.Position
            //         - line: 12
            //         - character: 8
            //   ▿ (2 elements)
            //     - key: "declarationFragments"
            //     ▿ value: SymbolKit.SymbolGraph.Symbol.DeclarationFragments
            //       ▿ declarationFragments: 5 elements
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "keyword"
            //           - spelling: "let"
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "text"
            //           - spelling: " "
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "identifier"
            //           - spelling: "nul"
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "text"
            //           - spelling: ": "
            //           - preciseIdentifier: nil
            //         ▿ SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment
            //           ▿ kind: SymbolKit.SymbolGraph.Symbol.DeclarationFragments.Fragment.Kind
            //             - rawValue: "typeIdentifier"
            //           - spelling: "NSNull"
            //           ▿ preciseIdentifier: Optional("c:objc(cs)NSNull")
            //             - some: "c:objc(cs)NSNull"


            let nested = try symFromName("nestedStruct")
            XCTAssertEqual(.property, nested.kind.identifier)
            XCTAssertEqual(.init(rawValue: "internal"), nested.accessLevel)
            XCTAssertEqual(nil, nested.type)
            XCTAssertEqual("NestedStruct", nested.names.subHeading?.last?.spelling)
            XCTAssertEqual("s:6source5BasicV12NestedStructV", nested.names.subHeading?.last?.preciseIdentifier)
            dump(nested, name: "nested")

            XCTAssertEqual("Int", try symFromName("int2").names.subHeading?.last?.spelling)
            XCTAssertEqual("s:Si", try symFromName("int2").names.subHeading?.last?.preciseIdentifier)

            XCTAssertEqual("String", try symFromName("str").names.subHeading?.last?.spelling)
            XCTAssertEqual("s:SS", try symFromName("str").names.subHeading?.last?.preciseIdentifier)

            XCTAssertEqual("String", try symFromName("str2").names.subHeading?.last?.spelling)
            XCTAssertEqual("s:SS", try symFromName("str2").names.subHeading?.last?.preciseIdentifier)
        }
    }

    func testSimpleTranslation() throws {
        try compare(swift: "1+2", kotlin: "1 + 2")
        try compare(swift: "{ return 1+2 }", kotlin: "{ 1 + 2 }")
        try compare(swift: #""abc"+"def""#, kotlin: #""abc" + "def""#)
        try compare(swift: #"[1,2,3].map({ x in "Number: \(x)" })"#, kotlin: #"listOf(1, 2, 3).map({ x -> "Number: ${x}" })"#)

        try compare(swift: "{ return 1+2 }", kotlin: "{ 1 + 2 }")

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
        fun getMessage(): String {
            return "Hello Skiff!"
        }

        println(getMessage())
        """

        try compare(swift: swift, kotlin: kotlin)
    }

    func testBasic() async throws {
        try await check(swift: 6, kotlin: 6) { _ in
            1+2+3
        } verify: {
            "1 + 2 + 3"
        }

        try await check(swift: 6, kotlin: 6) { _ in
            1.0+2.0+3.0
        } verify: {
            "1.0 + 2.0 + 3.0"
        }

        try await check(swift: "XYZ", kotlin: "XYZ") { _ in
            "X" + "Y" + "Z"
        } verify: {
            #""X" + "Y" + "Z""#
        }
    }

    func testListConversions() async throws {
        try await check(swift: [10], kotlin: [10]) { _ in
            (1...10).filter({ $0 > 9 })
        } verify: {
            "(1..10).filter({ it > 9 })"
        }

        try await check(swift: [2, 3, 4], kotlin: [2, 3, 4]) { _ in
            [1, 2, 3].map({ $0 + 1 })
        } verify: {
            "listOf(1, 2, 3).map({ it + 1 })"
        }

        try await check(swift: 15, kotlin: 15) { _ in
            [1, 5, 9].reduce(0, { x, y in x + y })
        } verify: {
            "listOf(1, 5, 9).fold(0, { x, y -> x + y })"
        }

        // demonstration that Gryphon mis-translates anonymous closure parameters beyond $0
        try await check(swift: 15) { _ in
            [1, 5, 9].reduce(0, { $0 + $1 })
        } verify: {
            "listOf(1, 5, 9).fold(0, { it + $1 })"
        }
    }

    func testEnumToEnum() async throws {
        try await check(swift: "dog", kotlin: "dog") { _ in
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

        try await check(swift: "meow", kotlin: "meow") { _ in
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

    func testStructToDataClass() async throws {
        try await check(swift: 7, kotlin: 7) { _ in
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

    func testTranslationComments() async throws {
        var tmpdir = NSTemporaryDirectory()
        #if os(Linux)
        let jtmpdir = tmpdir.trimmingTrailingCharacters(in: CharacterSet(["/"]))
        #else
        let jtmpdir = tmpdir
        #endif

        try await check(autoport: true, swift: String?.some(tmpdir), java: String?.some(jtmpdir), kotlin: .str(jtmpdir)) { jvm in
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
    func testMutableStructsBehaveDifferently() async throws {
        try await check(swift: 12, kotlin: .num(12 + 1)) { _ in
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

    func testGenerateFunctionBuilder() async throws {
        // does not compile, so we do not verify:

        // failed: caught error: "ERROR Data class must have at least one primary constructor parameter (ScriptingHost54e041a4_Line_6.kts:1:50)

        try await check(swift: [4, 6, 15], kotlin: .none) { _ in
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

    func testGenerateCompose() async throws {
        try await check(swift: 0, kotlin: 0) { _ in
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

//    func testComposeFunctions() throws {
//        try check(compile: false, swift: 0, kotlin: 0) { _ in
//            #if GRYPHON
//            class RootView: ComposeView {
//                func body() -> ComposeView {
//                    return TabView { [
//                        ContentView(),
//                        DestinationTwo(),
//                        ContentView(),
//                    ] }
//                }
//
//                @Composable
//                override func Compose(context: ComposeContext) {
//                    body().Compose(context)
//                }
//            }
//            #endif
//
//            return 0
//        } verify: {
//            """
//            """
//        }
//
//    }

    func testCrossPlatformTmpDir() async throws {
        let tmpdir = NSTemporaryDirectory()
        #if os(Linux)
        let jtmpdir = tmpdir.trimmingTrailingCharacters(in: CharacterSet(["/"]))
        #else
        let jtmpdir = tmpdir
        #endif
        try await check(autoport: true, swift: String?.some(tmpdir), java: jtmpdir, kotlin: .str(jtmpdir)) { jvm in
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

    func testCrossPlatformRandom() async throws {
        try await check(autoport: true, swift: true, java: true, kotlin: .bol(true)) { jvm in

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

    func testTranspileKotlinBlocks() async throws {
        try await check(autoport: true, swift: false, kotlin: .bol(true)) { jvm in
            func doSomething() -> Bool {
                #if KOTLIN
                return true
                #else
                return false
                #endif
            }
            return doSomething()
        } verify: {
        """
        fun doSomething(): Boolean {
            return true
        }

        doSomething()

        """
        }
    }

    func testPreprocessorRandom() async throws {
        try await check(autoport: true, swift: true, java: true, kotlin: .bol(true)) { jvm in

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

    func testPreprocessorRandomVal() async throws {
        try await check(autoport: true, swift: true, java: true, kotlin: .bol(true)) { jvm in

            func generateRandomNumber() throws -> Int64 {
                #if KOTLIN
                let rnd: java.util.Random = java.util.Random()
                return rnd.nextLong()
                #else
                return Int64.random(in: (.min)...(.max))
                #endif
            }

            return try generateRandomNumber() != generateRandomNumber()
        } verify: {
        """
        fun generateRandomNumber(): Long {
            val rnd: java.util.Random = java.util.Random()
            return rnd.nextLong()
        }

        generateRandomNumber() != generateRandomNumber()
        """
        }
    }

    func testStaticCompanionFunctions() async throws {
        try await check(autoport: true, swift: "abc", java: "abc", kotlin: .str("abc")) { jvm in
            class Foo {
                init() {
                }

                static func bar() -> String {
                    return "abc"
                }
            }

            return Foo.bar()
        } verify: {
        """
        internal open class Foo {
            companion object {
                fun bar(): String {
                    return "abc"
                }
            }

            constructor() {
            }
        }

        Foo.bar()
        """
        }
    }

    func testKotlinBlock() async throws {
        try await check(compile: false, autoport: true, swift: true, kotlin: .bol(false)) { jvm in

            func testKotlinBlock() throws -> Bool {
                #if KOTLIN
                enum Pet : String {
                    case cat, dog
                }
                let pet = Pet.dog
                //pet = .cattt
                pet = Pet.mouse // we tolerate a non-existent type and `let` reassignment
                pet = 1 // wrong type is allowed
                pet = z // non-existent local var permitted

                pet.pet.pet = pet // this makes no sense!
                return false
                #else
                return true
                #endif
            }

            return try testKotlinBlock()
        } verify: {
        """
         fun testKotlinBlock(): Boolean {
            enum class Pet(val rawValue: String) {
                CAT(rawValue = "cat"),
                DOG(rawValue = "dog");

                companion object {
                    operator fun invoke(rawValue: String): Pet? = values().firstOrNull { it.rawValue == rawValue }
                }
            }

            val pet: Pet = Pet.DOG

            //pet = .cattt
            pet = Pet.MOUSE

            // we tolerate a non-existent type and `let` reassignment
            pet = 1

            // wrong type is allowed
            pet = z

            // non-existent local var permitted
            pet.pet.pet = pet

            // this makes no sense!
            return false
        }

        testKotlinBlock()
        """
        }
    }

    // one possible solution…

    #if KOTLIN
    typealias LocalURL = java.io.File
    typealias RemoteURL = java.net.URL
    #else
    typealias LocalURL = Foundation.URL
    typealias RemoteURL = Foundation.URL
    #endif

    /// `Foundation.URL` does not have a single obvious analog in Java, which has both `java.io.File` and `java.net.URL`.
    func testFoundationURLTranslation() async throws {
        try await check(compile: true, autoport: true, swift: "/tmp", kotlin: .str("/tmp")) { jvm in

            #if KOTLIN
            typealias URL = java.io.File
            #else
            
            #endif

            func makeURL(path: String) -> URL {
                #if KOTLIN
                java.io.File(path)
                #else
                URL(fileURLWithPath: "/tmp/", isDirectory: true)
                #endif
            }

            func getPath(url: URL) -> String {
                #if KOTLIN
                url.getPath()
                #else
                url.path
                #endif
            }

            return getPath(url: makeURL(path: "/tmp"))
        } verify: {
        """
        internal typealias URL = java.io.File

        fun makeURL(path: String): URL = java.io.File(path)

        fun getPath(url: URL): String = url.getPath()

        getPath(makeURL("/tmp"))
        """
        }
    }


    func testAsyncFunctionsNotTranslated() async throws {
        try await check(autoport: true, swift: true, java: true, kotlin: true) { jvm in
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
    }

    func testDeferStatementsMistranslated() async throws {
        // defer turns into finally, which is given the wrong scope for the var x and yields the following compile error:

        // SkiffTests.swift:558: error: -[SkiffTests.SkiffTests testDeferStatementsNotTranslated] : failed: caught error: "ERROR Unresolved reference: x (ScriptingHost54e041a4_Line_0.kts:9:9)

        // and trying to next it raises:

        // error: failed to translate Gryphon AST into Kotlin: Defer statements are only supported as top-level statements in function bodies.

        try await check(compile: false, autoport: true, swift: 1, kotlin: 1) { jvm in
            func someFunc() -> Int {
                var x = 1
                defer { x += 1 }
                return x
            }

            return someFunc()
        } verify: {
        """
        fun someFunc(): Int {
            try {
                var x: Int = 1
                return x
            }
            finally {
                x += 1
            }
        }

        someFunc()
        """
        }

    }

    func testDeinitBlockMistranslated() async throws {
        await XCTAssertThrowsErrorAsync(try await check(compile: true, autoport: true, swift: true, kotlin: true) { jvm in
            class Foo {
                init() {
                }

                // we might expect this to be translated into a finally block…
                deinit {
                }
            }
            return true
        } verify: {
        """
        """
        }) { error in
            XCTAssertTrue("\(error)".contains("Unknown declaration (failed to translate SwiftSyntax node)."), "unexpected error: \(error)")
        }
    }

    func testEnumAssociatedCases() async throws {
        try await check(compile: true, autoport: true, swift: true, kotlin: true) { jvm in
            enum Pet {
                case cat
                case other(name: String)
            }
            return true
        } verify: {
        """
        internal sealed class Pet {
            class cat: Pet()
            class other(val name: String): Pet()
        }

        true
        """
        }
    }

    func testEnumAssociatedCasesMistranslated() async throws {
        await XCTAssertThrowsErrorAsync(try await check(compile: true, autoport: true, swift: "cat", kotlin: "cat") { jvm in
            enum Pet {
                case cat
                case other(name: String)
            }
            var p = Pet.cat
            p = .cat
            let petName: String
            switch p {
            case .cat: petName = "cat"
            case .other(let name): petName = name
            }
            return petName
        } verify: {
        """
        """
        }) { error in
            // error: Please add the associated value's label, e.g. "case .other(label: ...)" (failed to translate SwiftSyntax node).
            XCTAssertTrue("\(error)".contains("Please add the associated value's label"), "unexpected error: \(error)")
        }
    }

    func testStringInterpolationTranspilation() async throws {
        try await check(swift: "3", kotlin: "3") { _ in
            "\(1 + 2)"
        } verify: {
            """
            "${1 + 2}"
            """
        }

        try await check(autoport: true, swift: "3", kotlin: "3") { _ in
            func add(x: Int, y: Int) -> Int {
                x + y
            }
            return "\(add(x: 1, y: 2))"
        } verify: {
            """
            fun add(x: Int, y: Int): Int = x + y

            "${add(x = 1, y = 2)}"
            """
        }

    }

    func testWeakRefMisTranslation() async throws {
        try await check(compile: false, swift: true, kotlin: true) { _ in
            class XYZ {
                var a: String
                // doesn't translate into Kotlin correctly
                weak var b: XYZ?

                init(a: String, b: XYZ?) {
                    self.a = a
                    self.b = b
                }
            }

            return true
        } verify: {
            """
             internal open class XYZ {
                open var a: String

                // doesn't translate into Kotlin correctly
                weak open var b: XYZ? = null

                constructor(a: String, b: XYZ?) {
                    this.a = a
                    this.b = b
                }
            }

            true
            """
        }
    }

    func compareSymbols(sourceName: String = "source", swift: String, symbols: @autoclosure () throws -> SymbolGraph? = nil, check: ((SymbolGraph) throws -> ())? = nil, file: StaticString = #file, line: UInt = #line) throws {
        let tmproot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tmpdir = URL(fileURLWithPath: UUID().uuidString, isDirectory: true, relativeTo: tmproot)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        let tmpFile = URL(fileURLWithPath: "\(sourceName).swift", isDirectory: false, relativeTo: tmpdir)
        print("writing to:", tmpFile.path)
        try swift.write(to: tmpFile, atomically: true, encoding: .utf8)

        // for a full build docc: https://github.com/apple/swift-docc/blob/main/Sources/generate-symbol-graph/main.swift#L157
        /*
         swift build --package-path \(packagePath.path) \
           --scratch-path \(buildDirectory.path) \
           --target SwiftDocC \
           -Xswiftc -emit-symbol-graph \
           -Xswiftc -emit-symbol-graph-dir -Xswiftc \(symbolGraphOutputDirectory.path) \
           -Xswiftc -symbol-graph-minimum-access-level -Xswiftc internal
         */

        let process = Process()
        //process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh", isDirectory: false)
        //var args: [String] = ["-c"]
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
        var args: [String] = []

        args += ["swiftc"]
        args += [
            "-emit-symbol-graph",
            "-emit-module-path", tmpdir.path,
            "-emit-symbol-graph-dir", tmpdir.path,
            "-symbol-graph-minimum-access-level", "internal",
        ]

        args += [
            tmpFile.path
        ]

        process.arguments = args

        print("running:", args.joined(separator: " "))
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


        // TODO: find the correct output folder
        let symFile = URL(fileURLWithPath: "\(sourceName).symbols.json", isDirectory: false, relativeTo: tmpdir)
        let graphData = try Data(contentsOf: symFile)
        var graph = try JSONDecoder().decode(SymbolGraph.self, from: graphData)

        // first run any graph check block that may have been passed
        try check?(graph)

        graph.metadata.formatVersion = .init(major: 0, minor: 0, patch: 0)
        graph.metadata.generator = "skiff"
        graph.module.platform = .init()
        var sym2 = try graph.json(outputFormatting: [.prettyPrinted, .withoutEscapingSlashes]).utf8String ?? ""
        sym2 = sym2.replacingOccurrences(of: tmpdir.absoluteString, with: "") // strip the tmp URLs
        //print("### generated symbols", sym2)
        if let sym = try symbols() {
            // SymbolGraph is not equatable, so the best we can do is compare the encoded JSON
            let sym1 = try sym.json(outputFormatting: [.prettyPrinted, .withoutEscapingSlashes]).utf8String ?? ""

            XCTAssertEqual(sym1, sym2, file: file, line: line)
        }
    }

    func compare(swift: String, kotlin: String, symbols: SymbolGraph? = nil, file: StaticString = #file, line: UInt = #line) throws {
        if let symbols = symbols {
            try compareSymbols(swift: swift, symbols: symbols, file: file, line: line)
        }
        XCTAssertEqual(kotlin.trimmed(), try Skiff().translate(swift: swift, moduleName: nil, file: file, line: line).trimmed(), file: file, line: line)
    }

    /// Run a few simple simple Kotlin snippets and check their output
    func testKotlinSnippets() throws {
        let ctx = try Self.skiff.get().context
        XCTAssertEqual(3, try ctx.eval("1+2").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ 'a'; 1+2 }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ val x = 3; x }()").jsum())
        XCTAssertEqual(3, try ctx.eval("{ val x = 2; var y = 1; x + y; }()").jsum())
        //XCTAssertEqual(3, try ctx.eval("return 1+2").jsum())
        //XCTAssertEqual(3, try ctx.eval("{ val x = 1+2; return x }()").jsum())
    }
}



extension SymbolGraph {
    /// An empty graph for testing
    fileprivate static let empty: SymbolGraph = SymbolGraph(metadata: SymbolGraph.Metadata(formatVersion: SymbolGraph.SemanticVersion(major: 0, minor: 0, patch: 0, prerelease: nil, buildMetadata: nil), generator: "skiff"), module: SymbolGraph.Module(name: "source", platform: .init(architecture: nil, vendor: nil, operatingSystem: nil, environment: nil), version: nil, bystanders: nil, isVirtual: false), symbols: [], relationships: [])
}

// MARK: FileSystemModuleBlock

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

extension SkiffTests {
    func testGenerateModuleInterface() async throws {
        XCTAssertTrue(try JavaFileSystemModule().exists(at: "/dev/null"))
        XCTAssertTrue(try SwiftFileSystemModule().exists(at: "/dev/null"))

        XCTAssertFalse(try JavaFileSystemModule().exists(at: "/etc/NOT_A_FILE"))
        XCTAssertFalse(try SwiftFileSystemModule().exists(at: "/etc/NOT_A_FILE"))

        // Must be top-level, or else: Protocol 'FileSystemModule' cannot be nested inside another declaration
        let preamble = FileSystemModuleBlockStart..<FileSystemModuleBlockEnd
        try await check(compile: true, autoport: true, swift: true, java: true, kotlin: .bol(true), preamble: preamble) { jvm in
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
}


// MARK: StructExtensionModule

let StructExtensionModuleBlockStart = #line

public struct StructExtensionDemo {
    public let x: Int
}

extension StructExtensionDemo {
    public func abc() -> String {
        "abc"
    }
}

let StructExtensionModuleBlockEnd = #line

extension SkiffTests {
    func testStructExtensionTranslation() async throws {
        try await check(autoport: true, swift: "abc", kotlin: .str("abc"), preamble: StructExtensionModuleBlockStart..<StructExtensionModuleBlockEnd) { jvm in
            let demo = StructExtensionDemo(x: 1)
            return demo.abc()
        } verify: {
        """
         data class StructExtensionDemo(
            val x: Int
        )

        fun StructExtensionDemo.abc(): String = "abc"

        internal val demo: StructExtensionDemo = StructExtensionDemo(x = 1)

        demo.abc()
        """
        }
    }
}



// MARK: StaticExtensionModule

let StaticExtensionModuleBlockStart = #line

class StaticExtensionDemo {
    init() { }
}

extension StaticExtensionDemo {
    static func abc() -> String { "xyz" }
}

let StaticExtensionModuleBlockEnd = #line

extension SkiffTests {
    func testStaticFuncExtensionMistranslation() async throws {
        await XCTAssertThrowsErrorAsync(try await check(autoport: true, swift: "abc", java: "abc", kotlin: .str("abc"), preamble: StaticExtensionModuleBlockStart..<StaticExtensionModuleBlockEnd) { jvm in
            "abc"
        } verify: {
        """
        """
        }) { error in
            XCTAssertTrue("\(error)".contains("ERROR Unresolved reference: Companion"), "unexpected error: \(error)")
        }
    }
}

// MARK: StringExtensionModule

let StringExtensionModuleBlockStart = #line

#if KOTLIN
func fetch(url: String) async throws -> String {
    // FIXME: not really async
    return ""
}
#else

func fetch(url: String) async throws -> String {
    // FIXME: not really async
    try String(contentsOf: URL(string: url)!, encoding: .utf8)
}
#endif

let StringExtensionModuleBlockEnd = #line

extension SkiffTests {
    // not yet working
    func XXXtestStringExtensionTranslation() async throws {
        try await check(autoport: true, swift: true, kotlin: .bol(true), preamble: StringExtensionModuleBlockStart..<StringExtensionModuleBlockEnd) { jvm in
            func checkContents() async throws -> Bool {
                let string = try await fetch(url: "https://example.org")
                return string.contains("Example Domain")
            }
            return try await checkContents()
        } verify: {
        """
        """
        }
    }
}




/// Works around lack of async support in `XCTAssertThrowsError`
func XCTAssertThrowsErrorAsync<T>(_ asyncExpression: @autoclosure () async throws -> T, message: String? = nil, file: StaticString = #file, line: UInt = #line, errorHandler: (Error) -> ()) async {
    let result: Result<T, Error>
    do {
        result = .success(try await asyncExpression())
    } catch {
        result = .failure(error)
        //print("XCTAssertThrowsErrorAsync: \(error)")
    }

    XCTAssertThrowsError(try result.get(), message ?? "\(result)", file: file, line: line) { error in
        errorHandler(error)
    }
}

#endif

