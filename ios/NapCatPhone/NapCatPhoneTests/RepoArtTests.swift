@testable import NapCatPhone
import Testing
import UIKit

/// The repository's own art is bundled in place and loads by name.
@Suite struct RepoArtTests {
    @Test func theGroomingCatIsBundled() throws {
        let image = try #require(UIImage(named: RepoArt.groom))
        #expect(image.size.width > 0 && image.size.width == image.size.height)
    }

    @Test(arguments: Array(RepoArt.idleFrames))
    func everyIdleFrameIsBundledAtTwoX(_ index: Int) throws {
        let image = try #require(UIImage(named: RepoArt.idleFrameName(index)))
        #expect(image.size.width * image.scale == RepoArt.idleFramePixels)
        #expect(image.size.height * image.scale == RepoArt.idleFramePixels)
    }

    @Test func theCycleEndsSettled() {
        #expect(RepoArt.idleFrames.upperBound == RepoArt.idleSettledFrame)
        #expect(RepoArt.idleFrameName(-3) == "idle0")
        #expect(RepoArt.idleFrameName(99) == "idle16")
    }
}
