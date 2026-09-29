import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

private func makeStorage() -> IslandSettingsStorage {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("GrokIslandBackground-\(UUID().uuidString)", isDirectory: true)
    return IslandSettingsStorage(folder: folder, defaultsSuite: "GrokIslandTests-\(UUID().uuidString)")
}

private func writeFile(_ name: String, bytes: Int = 16) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("GrokIslandPick-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(repeating: 0xAB, count: bytes).write(to: url)
    return url
}

final class IslandRGBTests: XCTestCase {
    func testHexRoundTripAndShortForm() throws {
        let color = try XCTUnwrap(IslandRGB(hex: "#00a8C0"))
        XCTAssertEqual(color.hex, "#00A8C0")
        XCTAssertEqual(IslandRGB(hex: "fff"), IslandRGB(red: 1, green: 1, blue: 1))
        XCTAssertEqual(IslandRGB(hex: " #0B1030 \n")?.hex, "#0B1030")
        XCTAssertNil(IslandRGB(hex: "#12345"))
        XCTAssertNil(IslandRGB(hex: "zzzzzz"))
    }

    func testComponentsAreClamped() {
        let color = IslandRGB(red: 2, green: -1, blue: .nan)
        XCTAssertEqual(color.hex, "#FF0000")
    }

    func testLuminanceOrdersBlackBelowWhite() throws {
        XCTAssertEqual(IslandRGB(red: 0, green: 0, blue: 0).luminance, 0, accuracy: 1e-9)
        XCTAssertEqual(IslandRGB(red: 1, green: 1, blue: 1).luminance, 1, accuracy: 1e-9)
        let navy = try XCTUnwrap(IslandRGB(hex: "#0B1030"))
        XCTAssertLessThan(navy.luminance, 0.05)
    }
}

final class IslandBackgroundStyleTests: XCTestCase {
    func testDefaultIsAuroraWithoutVeilFloor() {
        let style = IslandBackgroundStyle.default
        XCTAssertEqual(style.kind, .aurora)
        XCTAssertFalse(style.usesCustomFill)
        XCTAssertEqual(style.minimumDim, 0)
    }

    func testBrightFillsRaiseTheVeilFloor() {
        var style = IslandBackgroundStyle()
        style.kind = .solid
        style.dim = 0
        style.opacity = 1
        style.solid = IslandRGB(red: 0.04, green: 0.06, blue: 0.19)
        XCTAssertEqual(style.effectiveDim, 0, "a dark navy needs no forced veil")

        style.solid = IslandRGB(red: 1, green: 1, blue: 1)
        XCTAssertGreaterThan(style.effectiveDim, 0.5, "white must be veiled so white text stays readable")
        XCTAssertLessThanOrEqual(style.effectiveDim, IslandBackgroundStyle.dimRange.upperBound)

        let opaqueFloor = style.minimumDim
        style.opacity = 0.5
        XCTAssertLessThan(style.minimumDim, opaqueFloor, "a see-through fill lets the dark glass do some of the work")

        style.dim = 0.7
        XCTAssertEqual(style.effectiveDim, 0.7, "the slider wins when it asks for more than the floor")
    }

    func testGradientFloorFollowsItsBrightestStop() {
        var style = IslandBackgroundStyle()
        style.kind = .gradient
        style.dim = 0
        style.opacity = 1
        style.gradient = [IslandRGB(red: 0, green: 0, blue: 0), IslandRGB(red: 0, green: 0, blue: 0)]
        XCTAssertEqual(style.minimumDim, 0)
        style.gradient.append(IslandRGB(red: 1, green: 1, blue: 0.2))
        XCTAssertGreaterThan(style.minimumDim, 0.4)
    }

    func testImagesAlwaysGetSomeVeil() {
        var style = IslandBackgroundStyle()
        style.kind = .image
        style.dim = 0
        XCTAssertEqual(style.effectiveDim, IslandBackgroundStyle.imageMinimumDim)
    }

    func testGradientPointsFollowTheAngle() {
        var style = IslandBackgroundStyle()
        style.gradientAngle = 0
        var points = style.gradientPoints
        XCTAssertEqual(points.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(points.start.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(points.end.x, 1, accuracy: 1e-9)

        style.gradientAngle = 90
        points = style.gradientPoints
        XCTAssertEqual(points.start.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(points.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(points.end.y, 1, accuracy: 1e-9)
    }

    func testSanitizedClampsValuesAndRepairsStops() {
        var style = IslandBackgroundStyle()
        style.dim = 5
        style.opacity = 0
        style.imageBlur = -3
        style.auroraOverlay = .infinity
        style.gradientAngle = 720
        style.gradient = [IslandRGB(red: 1, green: 0, blue: 0)]
        style.imageFileName = "../escape.png"

        let clean = style.sanitized()
        XCTAssertEqual(clean.dim, IslandBackgroundStyle.dimRange.upperBound)
        XCTAssertEqual(clean.opacity, IslandBackgroundStyle.opacityRange.lowerBound)
        XCTAssertEqual(clean.imageBlur, 0)
        XCTAssertEqual(clean.auroraOverlay, 0.25)
        XCTAssertEqual(clean.gradientAngle, 360)
        XCTAssertEqual(clean.gradient.count, 2)
        XCTAssertNil(clean.imageFileName)

        style.gradient = Array(repeating: IslandRGB(red: 0, green: 0, blue: 1), count: 7)
        XCTAssertEqual(style.sanitized().gradient.count, IslandBackgroundStyle.gradientStopRange.upperBound)
    }

    func testDecodingToleratesMissingAndUnknownFields() throws {
        let json = ##"{"kind":"gradient","gradient":["#101010","#FF00FF"],"dim":0.5,"future":"x"}"##
        let style = try JSONDecoder().decode(IslandBackgroundStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.kind, .gradient)
        XCTAssertEqual(style.gradient.map(\.hex), ["#101010", "#FF00FF"])
        XCTAssertEqual(style.dim, 0.5)
        XCTAssertEqual(style.opacity, IslandBackgroundStyle.default.opacity)

        let unknownKind = try JSONDecoder().decode(IslandBackgroundStyle.self, from: Data(#"{"kind":"video"}"#.utf8))
        XCTAssertEqual(unknownKind.kind, .aurora)
    }

    func testPresetsAreValid() {
        XCTAssertFalse(IslandBackgroundStyle.solidPresets.isEmpty)
        for preset in IslandBackgroundStyle.gradientPresets {
            XCTAssertTrue(IslandBackgroundStyle.gradientStopRange.contains(preset.colors.count), preset.title)
        }
        XCTAssertEqual(Set(IslandBackgroundStyle.gradientPresets.map(\.id)).count, IslandBackgroundStyle.gradientPresets.count)
    }
}

final class IslandBackgroundStorageTests: XCTestCase {
    func testStyleRoundTripsThroughDefaults() {
        let storage = makeStorage()
        XCTAssertEqual(storage.islandBackground, .default)

        var style = IslandBackgroundStyle()
        style.kind = .gradient
        style.gradient = IslandBackgroundStyle.gradientPresets[2].colors
        style.gradientAngle = 45
        style.dim = 0.4
        storage.islandBackground = style
        XCTAssertEqual(storage.islandBackground, style)

        let reopened = IslandSettingsStorage(folder: storage.folder, defaultsSuite: storage.defaultsSuite)
        XCTAssertEqual(reopened.islandBackground, style)
    }

    func testImportCopiesIntoApplicationSupportAndPrunes() throws {
        let storage = makeStorage()
        let source = try writeFile("wallpaper.JPG")

        let first = try storage.importBackgroundImage(from: source)
        XCTAssertTrue(first.hasSuffix(".jpg"))
        var style = IslandBackgroundStyle()
        style.kind = .image
        style.imageFileName = first
        let copied = try XCTUnwrap(storage.backgroundImageURL(for: style))
        XCTAssertEqual(copied.deletingLastPathComponent().standardizedFileURL, storage.backgroundsFolder.standardizedFileURL)

        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(storage.backgroundImageURL(for: style), "the copy outlives the original")

        let second = try storage.importBackgroundImage(from: try writeFile("next.png"))
        XCTAssertNotEqual(first, second)
        storage.pruneBackgroundImages(keeping: second)
        XCTAssertNil(storage.backgroundImageURL(for: style))
        style.imageFileName = second
        XCTAssertNotNil(storage.backgroundImageURL(for: style))
    }

    func testImportRejectsNonImagesAndHugeFiles() throws {
        let storage = makeStorage()
        XCTAssertThrowsError(try storage.importBackgroundImage(from: try writeFile("notes.txt"))) { error in
            XCTAssertEqual(error as? IslandBackgroundError, .unsupportedFormat("txt"))
        }
        XCTAssertThrowsError(try storage.importBackgroundImage(from: try writeFile("empty.png", bytes: 0))) { error in
            XCTAssertEqual(error as? IslandBackgroundError, .unreadable)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).png")
        XCTAssertThrowsError(try storage.importBackgroundImage(from: missing))

        let bigBytes = Int(IslandSettingsStorage.maxBackgroundImageBytes) + 1
        XCTAssertThrowsError(try storage.importBackgroundImage(from: try writeFile("huge.png", bytes: bigBytes))) { error in
            guard case .tooLarge = error as? IslandBackgroundError else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    func testTamperedFileNameCannotEscapeTheFolder() {
        let storage = makeStorage()
        var style = IslandBackgroundStyle()
        style.kind = .image
        style.imageFileName = "../../cursor-api-key"
        XCTAssertNil(storage.backgroundImageURL(for: style))
    }
}

@MainActor
final class IslandSettingsBackgroundTests: XCTestCase {
    func testPickingAnImagePersistsAndSurvivesRelaunch() async throws {
        let storage = makeStorage()
        let settings = IslandSettings(storage: storage)
        XCTAssertNil(settings.backgroundImageURL)

        try settings.importBackgroundImage(from: try writeFile("photo.heic"))
        XCTAssertEqual(settings.background.kind, .image)
        let firstURL = try XCTUnwrap(settings.backgroundImageURL)

        settings.background.imageBlur = 12
        settings.background.kind = .gradient
        let relaunched = IslandSettings(storage: IslandSettingsStorage(folder: storage.folder, defaultsSuite: storage.defaultsSuite))
        XCTAssertEqual(relaunched.background.kind, .gradient)
        XCTAssertEqual(relaunched.background.imageBlur, 12)
        XCTAssertEqual(relaunched.backgroundImageURL, firstURL, "switching kinds keeps the photo for later")

        try settings.importBackgroundImage(from: try writeFile("second.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path), "replaced images are cleaned up")

        settings.resetBackground()
        XCTAssertEqual(settings.background, .default)
        XCTAssertNil(settings.backgroundImageURL)
        XCTAssertEqual(storage.islandBackground, .default)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.backgroundsFolder.path), [])
    }

    func testFailedImportLeavesTheCurrentStyleAlone() async throws {
        let settings = IslandSettings(storage: makeStorage())
        settings.background.kind = .solid
        XCTAssertThrowsError(try settings.importBackgroundImage(from: try writeFile("doc.pdf")))
        XCTAssertEqual(settings.background.kind, .solid)
    }
}
