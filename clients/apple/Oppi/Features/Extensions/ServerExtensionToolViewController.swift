import UIKit

/// One parameter of a tool's arguments, as the tool page lists it: one level of
/// the JSON Schema's `properties`.
struct ServerToolParameter: Sendable, Equatable {
    let name: String
    /// The schema's type in words: "string", "number or null", "array of string",
    /// "any".
    let type: String
    let isRequired: Bool
    let description: String?

    /// The type, and whether a call must pass it: "string · Required".
    var valueLabel: String {
        isRequired ? "\(type) · \(String(localized: "Required"))" : type
    }

    /// The properties of `schema`, required ones first in the schema's own order
    /// (its `required` list keeps it), then the rest by name: the decoded object
    /// does not keep the order of its keys.
    static func list(in schema: JSONValue?) -> [ServerToolParameter] {
        guard let properties = schema?.objectValue?["properties"]?.objectValue else { return [] }
        let required = (schema?.objectValue?["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        let requiredSet = Set(required)
        let order = required.filter { properties[$0] != nil }
            + properties.keys.filter { !requiredSet.contains($0) }.sorted()
        return order.map { name in
            let property = properties[name]?.objectValue ?? [:]
            return ServerToolParameter(
                name: name,
                type: typeLabel(property),
                isRequired: requiredSet.contains(name),
                description: property["description"]?.stringValue
            )
        }
    }

    private static func typeLabel(_ property: [String: JSONValue]) -> String {
        if let type = property["type"]?.stringValue {
            if type == "array", let items = property["items"]?.objectValue, let itemType = items["type"]?.stringValue {
                return String(localized: "array of \(itemType)")
            }
            return type
        }
        let alternatives = property["type"]?.arrayValue?.compactMap(\.stringValue)
            ?? (property["anyOf"] ?? property["oneOf"])?.arrayValue?.compactMap { $0.objectValue?["type"]?.stringValue }
            ?? []
        if !alternatives.isEmpty { return alternatives.joined(separator: String(localized: " or ")) }
        if property["enum"] != nil { return String(localized: "one of a list") }
        return String(localized: "any")
    }
}

/// One tool an extension gives the model (pushed from the extension's detail):
/// its description, its parameters one level deep, the whole JSON Schema in the
/// reader, and for a classic Pi tool what it adds to Pi's default prompt. All of
/// it is the detail answer's `toolDefinitions` entry, held for the page's life.
@MainActor
final class ServerExtensionToolViewController: ListScreenController<
    ServerExtensionToolViewController.Section, ServerExtensionToolViewController.Item
> {
    enum Section: Hashable, Sendable {
        case description, parameters, schema, prompt
    }

    enum Item: Hashable, Sendable {
        case description
        case parameter(String)
        case schema
        case promptSnippet
        case promptGuidelines
    }

    let tool: ServerToolDefinition
    private let root: AppRootEnvironment
    private let parameters: [ServerToolParameter]

    init(tool: ServerToolDefinition, root: AppRootEnvironment) {
        self.tool = tool
        self.root = root
        parameters = ServerToolParameter.list(in: tool.parameters)
        super.init(title: tool.name, listIdentifier: "server.extensionTool.list", headers: true, footers: true)
        traitOverrides.appRootEnvironment = root
    }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    override var rowStyle: ListRowStyle { .card }

    override func sections() -> [ListSection<Section, Item>] {
        var sections: [ListSection<Section, Item>] = []
        if tool.description?.isEmpty == false {
            sections.append(ListSection(.description, items: [.description]))
        }
        if tool.parameters != nil {
            sections.append(ListSection(
                .parameters,
                header: "Parameters",
                footer: parameters.isEmpty ? String(localized: "The tool takes no arguments.") : nil,
                items: parameters.map { Item.parameter($0.name) }
            ))
            sections.append(ListSection(.schema, items: [.schema]))
        }
        var prompt: [Item] = []
        if tool.promptSnippet?.isEmpty == false { prompt.append(.promptSnippet) }
        if tool.promptGuidelines?.isEmpty == false { prompt.append(.promptGuidelines) }
        if !prompt.isEmpty {
            sections.append(ListSection(
                .prompt,
                header: "Prompt",
                footer: String(localized: "Pi adds these to its default system prompt while the tool is active."),
                items: prompt
            ))
        }
        return sections
    }

    override func showsHeader(for section: Section) -> Bool {
        section == .parameters || section == .prompt
    }

    /// Every row draws only the tool it was made with, which does not change;
    /// keyed so selectable text keeps its selection across passes.
    override func inputs(of item: Item) -> AnyHashable { AnyHashable(item) }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        let insets = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        switch item {
        case .description:
            ListScreen.staticRow(cell, identifier: "server.extensionTool.description")
            let text = tool.description ?? ""
            cell.contentConfiguration = ControlViewContent(insets: insets) {
                ControlRowViews.selectableText(text, style: .body, color: palette.ui.fg)
            }
        case .parameter(let name):
            ListScreen.staticRow(cell, identifier: "server.extensionTool.parameter.\(name)")
            guard let parameter = parameters.first(where: { $0.name == name }) else { return }
            cell.contentConfiguration = ControlViewContent(insets: insets) {
                let valueRow = ControlRowViews.valueRow(parameter.name, parameter.valueLabel, palette: palette, style: .body)
                guard let description = parameter.description, !description.isEmpty else { return valueRow }
                let detail = ControlRowViews.selectableText(description, style: .footnote, color: palette.ui.comment)
                return ControlRowViews.stack([valueRow, detail], spacing: 4)
            }
        case .schema:
            ListScreen.buttonRow(cell, identifier: "server.extensionTool.schema", label: String(localized: "JSON Schema")) { [weak self] in
                self?.openSchema()
            }
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "JSON Schema")
            content.textProperties.color = palette.ui.fg
            content.image = UIImage(systemName: "curlybraces")
            content.imageProperties.tintColor = palette.ui.blue
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .promptSnippet:
            ListScreen.staticRow(cell, identifier: "server.extensionTool.promptSnippet")
            labeledText(cell, title: String(localized: "Tool list"), text: tool.promptSnippet ?? "", insets: insets)
        case .promptGuidelines:
            ListScreen.staticRow(cell, identifier: "server.extensionTool.promptGuidelines")
            let bullets = (tool.promptGuidelines ?? []).map { "• \($0)" }.joined(separator: "\n")
            labeledText(cell, title: String(localized: "Guidelines"), text: bullets, insets: insets)
        }
    }

    /// A caption over selectable text.
    private func labeledText(_ cell: SidebarListCell, title: String, text: String, insets: NSDirectionalEdgeInsets) {
        let palette = palette
        cell.contentConfiguration = ControlViewContent(insets: insets) {
            ControlRowViews.stack([
                ControlRowViews.label(title, style: .footnote, color: palette.ui.comment),
                ControlRowViews.selectableText(text, style: .body, color: palette.ui.fg),
            ], spacing: 4)
        }
    }

    private func openSchema() {
        guard let schema = tool.parameters else { return }
        Router.push(ServerExtensionReaderViewController.schema(ofTool: tool.name, schema: schema, root: root), from: self)
    }
}
