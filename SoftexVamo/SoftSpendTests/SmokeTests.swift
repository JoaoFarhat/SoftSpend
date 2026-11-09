import Testing
@testable import SoftSpend

struct SmokeTests {
    @Test func appCompila() {
        #expect(Categoria.allCases.count == 5)
    }
}
