import Foundation
import Testing
@testable import WeftKit

struct LocalizationTests {
    @Test func editedDefaultsKeepTheUsersText() {
        var category = CategoryDefinition.defaults.first { $0.key == "code" }!
        category.name = "My code"
        category.hint = "Only Swift"
        #expect(category.displayName == "My code")
        #expect(category.displayHint == "Only Swift")
    }

    @Test func outputLanguageNamesTheScript() {
        #expect(OutputLanguage.name(for: "zh-Hans-SG").hasPrefix("Chinese, Simplified"))
        #expect(OutputLanguage.name(for: "zh-HK").hasPrefix("Chinese, Traditional"))
        #expect(OutputLanguage.name(for: "en-US").hasPrefix("English"))
        let simplified = ModelPrompts.describeInstructions(language: OutputLanguage.name(for: "zh-Hans-CN"))
        let traditional = ModelPrompts.describeInstructions(language: OutputLanguage.name(for: "zh-Hant-TW"))
        #expect(simplified.contains("在终端里开发"))
        #expect(!traditional.contains("在终端里开发"))
    }

    /// `swift test` copies the catalog without compiling it, so this reads the source file. These
    /// keys are looked up at runtime, so Xcode can't flag a missing one.
    @Test func everyDefaultCategoryAndScoreLabelIsTranslated() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/WeftKit/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        let keys = CategoryDefinition.defaults.flatMap { [$0.name, $0.hint] }.filter { !$0.isEmpty }
            + [100, 96, 95, 81, 80, 61, 60, 41, 40, 0].map(FocusScore.englishLabel(for:))
        for key in keys {
            #expect(catalog.strings[key]?.localizations?["zh-Hans"]?.stringUnit.value.isEmpty == false, "\(key)")
        }
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            var localizations: [String: Localization]?
        }
        struct Localization: Decodable {
            struct Unit: Decodable { var value: String }
            var stringUnit: Unit
        }
        var strings: [String: Entry]
    }
}
