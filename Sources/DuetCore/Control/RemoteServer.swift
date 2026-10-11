import Foundation
import Network

/// A small web page on this Mac's network address that controls Duet from the other Mac (or any
/// browser): play/pause, tracks, volumes, on/off. Nothing to install there: open the link once in
/// Safari. Every request needs the secret key carried by the link (then kept in a cookie).
public final class RemoteServer: @unchecked Sendable {
    public static let port: UInt16 = 47031

    /// Answers a command (`action` plus parameters) on the main queue; returns the state as JSON.
    public var handle: (@MainActor (_ action: String, _ parameters: [String: String]) -> [String: Any])?

    private let key: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "duet.remote")

    public init(key: String) { self.key = key }

    public func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() { listener?.cancel() }

    /// The link to open on the other Mac.
    public func link(host: String) -> String { "http://\(host):\(Self.port)/?key=\(key)" }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if done || error != nil || buffer.count > 16384 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let url = URLComponents(string: String(parts[1])) else { return send(400, "text/plain", Data(), on: connection) }
        var parameters = [String: String]()
        for item in url.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
        let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") }?
            .split(separator: ";").first { $0.contains("duet=") }?
            .split(separator: "=").last.map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parameters["key"] == key || cookie == key else {
            return send(403, "text/plain", Data("Open the link from Duet's menu on the Mac that plays.".utf8), on: connection)
        }
        switch url.path {
        case "/":
            send(200, "text/html; charset=utf-8", Data(Self.page.utf8), on: connection,
                 extra: "Set-Cookie: duet=\(key); Max-Age=31536000; Path=/; SameSite=Strict\r\n")
        case "/api":
            let action = parameters["action"] ?? "state"
            DispatchQueue.main.async {
                let state = MainActor.assumeIsolated { self.handle?(action, parameters) } ?? [:]
                let body = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
                self.queue.async { self.send(200, "application/json", body, on: connection) }
            }
        default:
            send(404, "text/plain", Data(), on: connection)
        }
    }

    private func send(_ status: Int, _ type: String, _ body: Data, on connection: NWConnection, extra: String = "") {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? ""
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // The page: state comes from /api every 2 s; every control sends one /api call.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Duet</title><meta name="apple-mobile-web-app-capable" content="yes">
    <style>
    :root{color-scheme:light dark;font:16px -apple-system,system-ui,sans-serif}
    body{margin:0 auto;max-width:420px;padding:20px 16px}
    h1{font-size:20px;display:flex;justify-content:space-between;align-items:center;margin:0 0 4px}
    #status{color:gray;font-size:13px;min-height:1.2em;margin-bottom:16px}
    .transport{display:flex;gap:12px;justify-content:center;margin:12px 0 20px}
    .transport button{font-size:26px;width:72px;height:56px;border-radius:14px;border:0;background:#8883}
    label{display:block;font-size:13px;color:gray;margin:14px 0 4px}
    input[type=range]{width:100%}
    </style></head><body>
    <h1>Duet <input type="checkbox" id="on" role="switch"></h1>
    <div id="status"></div>
    <div class="transport">
    <button onclick="api('previous')">⏮</button><button onclick="api('playPause')">⏯</button><button onclick="api('next')">⏭</button>
    </div>
    <div id="volumes"></div>
    <script>
    let dragging=false;
    async function api(action,params={}){
      const q=new URLSearchParams({action,...params});
      const r=await fetch('/api?'+q);render(await r.json());
    }
    function slider(id,name,value){
      let el=document.getElementById('v-'+id);
      if(!el){
        const label=document.createElement('label');label.textContent=name;
        el=document.createElement('input');el.type='range';el.min=0;el.max=1;el.step=0.01;el.id='v-'+id;
        el.oninput=()=>{dragging=true;api('volume',{id,value:el.value})};
        el.onchange=()=>{dragging=false};
        document.getElementById('volumes').append(label,el);
      }
      if(!dragging)el.value=value;
    }
    function render(s){
      document.getElementById('on').checked=s.on;
      document.getElementById('status').textContent=s.status;
      for(const v of s.volumes)slider(v.id,v.name,v.value);
    }
    document.getElementById('on').onchange=e=>api(e.target.checked?'on':'off');
    api('state');setInterval(()=>{if(!dragging)api('state')},2000);
    </script></body></html>
    """
}
