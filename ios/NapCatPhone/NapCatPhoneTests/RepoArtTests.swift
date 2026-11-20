@testable import NapCatPhone
import Testing
import UIKit

/// The repository's own art is bundled in place and loads by name.
@Suite struct RepoArtTests {
    @Test func theGroomingCatIsBundled() throws {
        let image = try #require(UIImage(named: RepoArt.groom))
        #expect(image.size.width > 0 && image.size.width == image.size.height)
    }
}
