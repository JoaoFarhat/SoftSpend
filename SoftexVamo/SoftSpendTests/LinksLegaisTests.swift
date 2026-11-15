import Testing
import Foundation
@testable import SoftSpend

struct LinksLegaisTests {
    @Test func urlsSaoHttpsNoDominioSoftspend() {
        for url in [LinksLegais.termos, LinksLegais.privacidade, LinksLegais.suporte] {
            #expect(url.scheme == "https")
            #expect(url.host() == "softspend.com.br")
        }
    }

    @Test func caminhos() {
        #expect(LinksLegais.termos.path() == "/termos")
        #expect(LinksLegais.privacidade.path() == "/privacidade")
        #expect(LinksLegais.suporte.path() == "/suporte")
    }
}
