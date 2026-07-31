#if os(Linux)
import Foundation
import NetLightsCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// SOCK_STREAM is a `__socket_type` enum under Glibc but a plain Int32 under Musl.
#if canImport(Glibc)
private let SOCK_STREAM_RAW = Int32(SOCK_STREAM.rawValue)
#else
private let SOCK_STREAM_RAW = SOCK_STREAM
#endif

/// A tiny, dependency-free HTTP/1.1 server (blocking accept loop, one connection at a
/// time — ample for a local single-user visualizer). Serves the live snapshot as JSON and
/// a small HTML/JS shell that polls it. No external packages, so the static musl binary
/// stays dependency-free. The SVG graph (rendered from the shared GraphLayoutEngine)
/// replaces the tables in the next slice (L2b).
struct LinuxServer {
    let host: String
    let port: UInt16

    func run() {
        let listenFD = socket(AF_INET, SOCK_STREAM_RAW, 0)
        guard listenFD >= 0 else { perror("socket"); return }
        defer { close(listenFD) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0   // INADDR_ANY (0.0.0.0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { perror("bind"); return }
        guard listen(listenFD, 16) == 0 else { perror("listen"); return }

        print("NetLights (Linux) — serving on http://\(host):\(port)  (Ctrl-C to stop)")
        print("  open it in a browser on this machine, or from your host at the VM's IP.")

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { continue }
            handle(clientFD)
            close(clientFD)
        }
    }

    private func handle(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return }
        let request = String(decoding: buf[0..<Int(n)], as: UTF8.self)
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        switch path {
        case "/snapshot.json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = (try? encoder.encode(LinuxCollector().snapshot()))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            respond(fd, status: "200 OK", type: "application/json", body: body)
        case "/graph.svg":
            let svg = renderGraphSVG(snapshot: LinuxCollector().snapshot())
            respond(fd, status: "200 OK", type: "image/svg+xml; charset=utf-8", body: svg)
        case "/", "/index.html":
            respond(fd, status: "200 OK", type: "text/html; charset=utf-8", body: Self.indexHTML)
        default:
            respond(fd, status: "404 Not Found", type: "text/plain", body: "not found")
        }
    }

    private func respond(_ fd: Int32, status: String, type: String, body: String) {
        let bytes = Array(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\n\r\n"
        _ = Array(header.utf8).withUnsafeBytes { writeAll(fd, $0) }
        bytes.withUnsafeBytes { writeAll(fd, $0) }
    }

    private func writeAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer) {
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < buf.count {
            let w = write(fd, base.advanced(by: sent), buf.count - sent)
            if w <= 0 { break }
            sent += w
        }
    }

    static let indexHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>NetLights (Linux)</title>
    <style>
      body{background:#0d1117;color:#c9d1d9;font:13px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:20px}
      h1{font-size:18px;margin:0 0 2px}.sub{color:#8b949e;margin-bottom:18px}
      table{border-collapse:collapse;width:100%;margin-bottom:22px}
      th,td{text-align:left;padding:5px 10px;border-bottom:1px solid #21262d;font-variant-numeric:tabular-nums}
      th{color:#8b949e;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
      .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
      h2{font-size:12px;color:#58a6ff;text-transform:uppercase;letter-spacing:.05em;margin:0 0 6px}
      .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
      .up{background:#3fb950}.down{background:#f85149}.unknown{background:#8b949e}
      .pill{background:#21262d;border-radius:10px;padding:1px 8px;font-size:11px}
    </style></head><body>
      <h1>NetLights <span class="pill">Linux</span></h1>
      <div class="sub" id="hdr">connecting…</div>
      <div id="graph" style="overflow:auto;border:1px solid #21262d;border-radius:8px;margin-bottom:22px"></div>
      <h2>Interfaces</h2><table id="ifaces"></table>
      <h2>Routes</h2><table id="routes"></table>
      <h2>Gateways</h2><table id="gws"></table>
      <h2>DNS</h2><table id="dns"></table>
    <script>
    const $=id=>document.getElementById(id);
    function cell(c,head){const e=document.createElement(head?'th':'td');if(c&&typeof c==='object'){e.innerHTML=c.html;if(c.mono)e.className='mono';}else{e.textContent=c==null?'':c;}return e;}
    function fill(t,hs,rs){const el=$(t);el.innerHTML='';const h=document.createElement('tr');for(const x of hs)h.appendChild(cell(x,true));el.appendChild(h);for(const r of rs){const tr=document.createElement('tr');for(const x of r)tr.appendChild(cell(x,false));el.appendChild(tr);}}
    function bytes(n){n=Number(n||0);if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';if(n<1073741824)return (n/1048576).toFixed(1)+' MB';return (n/1073741824).toFixed(2)+' GB';}
    async function tick(){try{
      const s=await(await fetch('/snapshot.json',{cache:'no-store'})).json();
      $('hdr').textContent=s.machineModel+'  ·  egress: '+(s.egress?(s.egress.viaInterface+' ('+s.egress.kind+')'):'—')+'  ·  '+s.interfaces.length+' interfaces';
      $('graph').innerHTML=await(await fetch('/graph.svg',{cache:'no-store'})).text();
      fill('ifaces',['','Interface','Type','IPv4','MAC','MTU','RX','TX'],s.interfaces.map(i=>[
        {html:'<span class="dot '+(i.linkState||'unknown')+'"></span>'},{html:i.id,mono:1},i.category,
        {html:(i.ipv4Addresses||[]).join(', '),mono:1},{html:i.macAddress||'—',mono:1},i.mtu,bytes(i.rxBytes),bytes(i.txBytes)]));
      fill('routes',['Destination','Gateway','Netmask','Interface','Flags'],s.routes.map(r=>[
        {html:r.destination,mono:1},{html:r.gateway||'—',mono:1},{html:r.netmask||'—',mono:1},{html:r.interfaceName,mono:1},{html:r.flags,mono:1}]));
      fill('gws',['Gateway','Default','VPN','Via'],s.gateways.map(g=>[
        {html:g.id,mono:1},g.isDefault?'★':'',g.isVPN?'🔒':'',{html:(g.reachableVia||[]).join(', '),mono:1}]));
      fill('dns',['Scope','Resolvers','Search'],(s.dnsConfigs||[]).map(d=>[
        d.scopeLabel,{html:(d.servers||[]).join('  '),mono:1},(d.searchDomains||[]).join(', ')]));
    }catch(e){$('hdr').textContent='error: '+e;}}
    tick();setInterval(tick,1000);
    </script></body></html>
    """
}
#endif
