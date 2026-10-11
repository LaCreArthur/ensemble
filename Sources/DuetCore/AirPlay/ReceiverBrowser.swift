import Foundation
import Network

/// Lists the other Macs that accept AirPlay on the local network (their built-in AirPlay Receiver).
/// This Mac's own receiver is left out.
public final class ReceiverBrowser: @unchecked Sendable {
    public struct Receiver: Hashable, Sendable, Identifiable {
        /// The receiver's stable hardware ID (TXT "deviceid"); survives renames.
        public let id: String
        public let name: String
        public let model: String
        public let endpoint: NWEndpoint
    }

    private let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: "local."), using: .tcp)
    private let ownName = Host.current().localizedName ?? ""

    /// Called on the main queue with the current list, sorted by name.
    public var onChange: (@MainActor ([Receiver]) -> Void)?

    public init() {}

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var byID = [String: Receiver]()
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint, name != self.ownName,
                      case .bonjour(let txt) = result.metadata,
                      let model = txt["model"], model.hasPrefix("Mac"), let id = txt["deviceid"] else { continue }
                byID[id] = Receiver(id: id, name: name, model: model, endpoint: result.endpoint)
            }
            let list = byID.values.sorted { $0.name < $1.name }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange?(list) } }
        }
        browser.start(queue: DispatchQueue(label: "duet.browser"))
    }

    public func stop() { browser.cancel() }
}
