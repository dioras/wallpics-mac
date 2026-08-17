import CoreGraphics
import Foundation

enum PetCatalog {
    private struct CatalogFile: Decodable {
        struct Entry: Decodable {
            let slug: String
            let name: String
        }
        let pets: [Entry]
    }

    private struct PetFile: Decodable {
        struct Point: Decodable {
            let x: Double
            let y: Double
        }
        let slug: String
        let name: String
        let width: Int
        let height: Int
        let poseCount: Int
        let neutralPose: Int
        let faceCenter: Point
        let angleBuckets: Int
        let angleTable: [Int]
        let mirrorTable: [Bool]?
        let pivotUp: Int?
        let pivotDown: Int?
    }

    static let all: [PetSpecies] = load()

    static func species(slug: String) -> PetSpecies? {
        all.first { $0.slug == slug }
    }

    private static var root: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Pets", isDirectory: true)
    }

    private static func load() -> [PetSpecies] {
        guard let root else {
            Log.app.error("PetCatalog: no resource root")
            return []
        }
        let catalogURL = root.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONDecoder().decode(CatalogFile.self, from: data) else {
            Log.app.error("PetCatalog: cannot read \(catalogURL.path, privacy: .public)")
            return []
        }
        return catalog.pets.compactMap { entry in
            let dir = root.appendingPathComponent(entry.slug, isDirectory: true)
            let metaURL = dir.appendingPathComponent("pet.json")
            let mediaURL = dir.appendingPathComponent("pet.mov")
            let posterURL = dir.appendingPathComponent("poster.png")
            guard let metaData = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(PetFile.self, from: metaData) else {
                Log.app.error("PetCatalog: cannot read metadata for \(entry.slug, privacy: .public)")
                return nil
            }
            guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                Log.app.error("PetCatalog: missing media for \(entry.slug, privacy: .public)")
                return nil
            }
            let mirrorCount = meta.mirrorTable?.count ?? meta.angleBuckets
            guard meta.angleTable.count == meta.angleBuckets,
                  mirrorCount == meta.angleBuckets,
                  meta.poseCount > 0 else {
                Log.app.error("PetCatalog: malformed gaze map for \(entry.slug, privacy: .public)")
                return nil
            }
            return PetSpecies(
                slug: meta.slug,
                name: entry.name,
                pixelWidth: meta.width,
                pixelHeight: meta.height,
                poseCount: meta.poseCount,
                neutralPose: meta.neutralPose,
                faceCenter: CGPoint(x: meta.faceCenter.x, y: meta.faceCenter.y),
                angleTable: meta.angleTable,
                mirrorTable: meta.mirrorTable ?? Array(repeating: false, count: meta.angleTable.count),
                pivotUp: meta.pivotUp ?? meta.neutralPose,
                pivotDown: meta.pivotDown ?? meta.neutralPose,
                mediaURL: mediaURL,
                posterURL: posterURL
            )
        }
    }
}
