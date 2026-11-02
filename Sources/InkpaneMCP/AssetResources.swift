import Foundation
import MCP
import InkpaneKit

// `screen://assets/recent` and `screen://assets/{id}`: the Inkpane app's capture library.
// Only available while the app is running and has allowed this client; excluded apps'
// captures are left out by the app.

extension ToolCatalog {
    public static let recentAssetsURI = "screen://assets/recent"
    public static let assetURIPrefix = "screen://assets/"
    public static let assetURITemplate = "screen://assets/{id}"

    static let assetResources: [Resource] = [
        Resource(
            name: "recent-assets",
            uri: recentAssetsURI,
            title: "Recent captures",
            description: "The newest captures in the Inkpane library: id, file path, time, source app, window title, URL, Git project and branch (for editor and terminal captures), pinned state and the start of the recognized text. Needs the Inkpane app.",
            mimeType: "application/json")
    ]

    public static let resourceTemplates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: assetURITemplate,
            name: "asset",
            title: "Library capture",
            description: "One capture from the Inkpane library as a PNG (longer edge at most \(ArgumentParsing.defaultMaxDimension) px), plus its metadata. Ids come from screen://assets/recent. Needs the Inkpane app.",
            mimeType: "image/png")
    ]
}

extension InkpaneTools {
    struct AssetMetadata: Encodable {
        var asset: BridgeAsset
        var returnedWidth: Int
        var returnedHeight: Int
        var privacy: PrivacyReport?
    }

    struct RecentAssets: Encodable {
        var assets: [BridgeAsset]
        var note: String?
    }

    func readAssetResource(uri: String) async throws -> ReadResource.Result {
        do {
            if uri == ToolCatalog.recentAssetsURI {
                let result = try await bridge.recentAssets(RecentAssetsParams(limit: RecentAssetsParams.defaultLimit))
                let note = result.hiddenCount > 0
                    ? "\(result.hiddenCount) capture(s) of apps on the user's privacy exclusion list are not listed." : nil
                return ReadResource.Result(contents: [
                    .text(JSON.encode(RecentAssets(assets: result.assets, note: note)), uri: uri, mimeType: "application/json")
                ])
            }
            let idText = String(uri.dropFirst(ToolCatalog.assetURIPrefix.count))
            guard let id = Int64(idText), id > 0 else {
                throw MCPError.invalidParams("Unknown resource: \(uri). Asset ids are numbers from \(ToolCatalog.recentAssetsURI).")
            }
            let result = try await bridge.asset(AssetParams(id: id))
            guard let data = Data(base64Encoded: result.pngBase64), let image = ImageUtilities.decodeImage(data) else {
                throw BridgeClientError.invalidResponse("asset image is not a valid PNG")
            }
            let scaled = try ImageUtilities.downscale(image, maxDimension: ArgumentParsing.defaultMaxDimension)
            let png = scaled === image ? data : try ImageUtilities.pngData(scaled)
            let metadata = AssetMetadata(
                asset: result.asset, returnedWidth: scaled.width, returnedHeight: scaled.height,
                privacy: result.privacy.flatMap { $0.isEmpty ? nil : $0 })
            return ReadResource.Result(contents: [
                .binary(png, uri: uri, mimeType: "image/png"),
                .text(JSON.encode(metadata), uri: uri, mimeType: "application/json"),
            ])
        } catch let error as MCPError {
            throw error
        } catch BridgeClientError.appNotRunning(let path) {
            throw MCPError.internalError(
                "The Inkpane library needs the Inkpane menu bar app, which is not running (nothing is listening on \(path)). Ask the user to start it.")
        } catch {
            throw MCPError.internalError(error.localizedDescription)
        }
    }
}
