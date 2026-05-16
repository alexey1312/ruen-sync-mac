@testable import RuEnSync
import Testing

struct LayoutResolverTests {
    @Test("maps ABC to index 0")
    func mapsABC() {
        let idx = LayoutResolver.resolveIndex(
            inputSourceID: "com.apple.keylayout.ABC",
            layouts: ["ABC", "Russian"]
        )
        #expect(idx == 0)
    }

    @Test("maps Russian to index 1 (treated as RU by firmware)")
    func mapsRussian() {
        let idx = LayoutResolver.resolveIndex(
            inputSourceID: "com.apple.keylayout.Russian",
            layouts: ["ABC", "Russian"]
        )
        #expect(idx == 1)
    }

    @Test("returns nil for unknown layout")
    func unknownLayoutFallsThrough() {
        let idx = LayoutResolver.resolveIndex(
            inputSourceID: "com.apple.keylayout.German",
            layouts: ["ABC", "Russian"]
        )
        #expect(idx == nil)
    }

    @Test("handles Ilya Birman typography layout variants")
    func ilyaBirmanVariants() {
        let layouts = ["English-IlyaBirmanTypography", "Russian-IlyaBirmanTypography"]
        let en = LayoutResolver.resolveIndex(
            inputSourceID: "org.ilyabirman.EnglishIlyaBirmanTypography.English-IlyaBirmanTypography",
            layouts: layouts
        )
        let ru = LayoutResolver.resolveIndex(
            inputSourceID: "org.ilyabirman.RussianIlyaBirmanTypography.Russian-IlyaBirmanTypography",
            layouts: layouts
        )
        #expect(en == 0)
        #expect(ru == 1)
    }

    @Test("treats id with no dots as the suffix itself")
    func noDots() {
        let idx = LayoutResolver.resolveIndex(
            inputSourceID: "ABC",
            layouts: ["ABC", "Russian"]
        )
        #expect(idx == 0)
    }
}
