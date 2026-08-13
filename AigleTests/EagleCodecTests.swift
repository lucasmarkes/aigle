import Foundation
import Testing

@testable import Aigle

@Suite("Eagle on-disk format")
struct EagleCodecTests {

    /// Exactly what Eagle 4 writes into `images/<id>.info/metadata.json`,
    /// including keys Aigle does not model.
    static let eagleItemJSON = """
    {
      "id": "KZ7X2M9QW1ABC",
      "name": "sunset over the bay",
      "size": 482913,
      "btime": 1712345678901,
      "mtime": 1712345678000,
      "ext": "jpg",
      "tags": ["landscape", "reference"],
      "folders": ["KLZ9F0P2QRSTU"],
      "isDeleted": false,
      "url": "https://example.com/sunset.jpg",
      "annotation": "Nice gradient in the sky.",
      "modificationTime": 1712345679000,
      "height": 1200,
      "width": 1920,
      "noThumbnail": false,
      "lastModified": 1712345679999,
      "deletedTime": 0,
      "palettes": [{ "color": [255, 128, 64], "ratio": 42 }],
      "star": 0
    }
    """

    @Test("Decoding an Eagle item reads every modelled field")
    func decodeItem() throws {
        let item = try EagleCodec.decodeItem(Data(Self.eagleItemJSON.utf8))
        #expect(item.id == "KZ7X2M9QW1ABC")
        #expect(item.name == "sunset over the bay")
        #expect(item.ext == "jpg")
        #expect(item.size == 482913)
        #expect(item.width == 1920)
        #expect(item.height == 1200)
        #expect(item.tags == ["landscape", "reference"])
        #expect(item.folders == ["KLZ9F0P2QRSTU"])
        #expect(item.isDeleted == false)
        #expect(item.annotation == "Nice gradient in the sky.")
        #expect(item.palettes.first?.color == [255, 128, 64])
        #expect(item.kind == .image)
        #expect(item.fileName == "sunset over the bay.jpg")
        #expect(item.thumbnailFileName == "sunset over the bay_thumbnail.png")
    }

    @Test("Round-tripping preserves Eagle keys Aigle does not model")
    func roundTripPreservesUnknownKeys() throws {
        let item = try EagleCodec.decodeItem(Data(Self.eagleItemJSON.utf8))
        #expect(item.passthrough["lastModified"]?.intValue == 1712345679999)
        #expect(item.passthrough["deletedTime"]?.intValue == 0)

        let encoded = EagleCodec.encodeItem(item)
        #expect(encoded["lastModified"]?.intValue == 1712345679999)
        #expect(encoded["deletedTime"]?.intValue == 0)

        let reDecoded = try EagleCodec.decodeItem(try EagleCodec.encodeItemData(item))
        #expect(reDecoded == item)
    }

    @Test("Aigle extras live in a namespaced sub-object")
    func aigleExtrasAreNamespaced() throws {
        var item = try EagleCodec.decodeItem(Data(Self.eagleItemJSON.utf8))
        item.aigle.liked = true
        item.aigle.blobID = "deadbeef"
        item.aigle.virtualCopyOf = "KAAAAAAAAAAAA"

        let encoded = EagleCodec.encodeItem(item)
        let aigle = try #require(encoded["aigle"]?.objectValue)
        #expect(aigle["liked"]?.boolValue == true)
        #expect(aigle["blobID"]?.stringValue == "deadbeef")
        #expect(aigle["virtualCopyOf"]?.stringValue == "KAAAAAAAAAAAA")
        // Nothing leaked into Eagle's own namespace.
        #expect(encoded["liked"] == nil)
        #expect(encoded["blobID"] == nil)

        let restored = try EagleCodec.decodeItem(encoded)
        #expect(restored.aigle == item.aigle)
        #expect(restored.liked)
    }

    @Test("A missing id is a decode error, not a silent default")
    func missingIDThrows() {
        #expect(throws: EagleCodecError.self) {
            try EagleCodec.decodeItem(Data(#"{"name":"x"}"#.utf8))
        }
    }

    @Test("Library metadata round-trips a nested collection tree")
    func libraryMetadataRoundTrip() throws {
        let json = """
        {
          "id": "LIB0000000001",
          "folders": [
            {
              "id": "KA1", "name": "Brand", "description": "", "children": [
                { "id": "KA2", "name": "Logos", "description": "", "children": [],
                  "modificationTime": 1, "tags": [], "iconColor": "", "password": "" }
              ],
              "modificationTime": 2, "tags": ["work"], "iconColor": "blue", "password": ""
            }
          ],
          "smartFolders": [],
          "quickAccess": [],
          "tagsGroups": [],
          "modificationTime": 3,
          "applicationVersion": "4.0.0"
        }
        """
        let metadata = try EagleCodec.decodeLibraryMetadata(Data(json.utf8))
        #expect(metadata.folders.count == 1)
        #expect(metadata.folders[0].name == "Brand")
        #expect(metadata.folders[0].children.first?.name == "Logos")
        #expect(metadata.folders[0].tags == ["work"])
        // Eagle's per-folder password field survives.
        #expect(metadata.folders[0].passthrough["password"]?.stringValue == "")

        let reEncoded = try EagleCodec.encodeLibraryMetadata(metadata)
        let restored = try EagleCodec.decodeLibraryMetadata(reEncoded)
        #expect(restored.folders == metadata.folders)
        #expect(restored.id == "LIB0000000001")
    }

    @Test("Custom item order is stored outside Eagle's schema")
    func customOrderIsNamespaced() throws {
        var collection = LibraryCollection(id: "KA1", name: "Moodboard")
        collection.customOrder = ["A", "B", "C"]
        let encoded = EagleCodec.encodeCollection(collection)
        #expect(encoded["aigleOrder"]?.arrayValue?.compactMap(\.stringValue) == ["A", "B", "C"])
        let restored = try #require(EagleCodec.decodeCollection(encoded))
        #expect(restored.customOrder == ["A", "B", "C"])
    }
}

@Suite("Collection tree operations")
struct CollectionTreeTests {
    private var tree: [LibraryCollection] {
        [
            LibraryCollection(id: "A", name: "Zebra", children: [
                LibraryCollection(id: "A1", name: "Yak"),
                LibraryCollection(id: "A2", name: "Ant"),
            ]),
            LibraryCollection(id: "B", name: "Alpha"),
        ]
    }

    @Test("Finding reaches nested collections")
    func find() {
        #expect(tree.find("A2")?.name == "Ant")
        #expect(tree.find("nope") == nil)
    }

    @Test("Removing prunes the whole subtree entry")
    func remove() {
        let pruned = tree.removing("A1")
        #expect(pruned.find("A1") == nil)
        #expect(pruned.find("A2") != nil)
    }

    @Test("Alphabetical sorting recurses")
    func sortAlphabetically() {
        let sorted = tree.sortedAlphabetically()
        #expect(sorted.map(\.name) == ["Alpha", "Zebra"])
        #expect(sorted.last?.children.map(\.name) == ["Ant", "Yak"])
    }

    @Test("Mutation is applied in place at any depth")
    func mutate() {
        let updated = tree.mutating("A1") { $0.name = "Renamed" }
        #expect(updated.find("A1")?.name == "Renamed")
        #expect(updated.find("A")?.children.count == 2)
    }

    @Test("Flattening lists parents before children")
    func flatten() {
        #expect(tree.flattened.map(\.id) == ["A", "A1", "A2", "B"])
    }
}
