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
      .pill{background:#21262d;border-radius:10px;padding:1px 8px;font-size:11px;font-weight:400}
      .topbar{display:flex;align-items:center;gap:16px;margin-bottom:4px}
      .brand{font-size:16px;font-weight:600}
      .tabs{display:flex;gap:2px;background:#161b22;border-radius:8px;padding:3px}
      .tab{background:none;border:none;color:#8b949e;font:inherit;font-size:13px;padding:5px 15px;border-radius:6px;cursor:pointer}
      .tab.active{background:#0d1117;color:#e6edf3}
      .tab-content[hidden]{display:none}
      .empty{color:#8b949e;padding:40px;text-align:center}
      #graph{overflow:auto;border:1px solid #21262d;border-radius:8px}
      @keyframes antcrawl{to{stroke-dashoffset:-20}}
      #graph path.wire.active{stroke-dasharray:6 5;animation:antcrawl .55s linear infinite}
      td.rate{color:#3fb950}
    </style></head><body>
      <div class="topbar">
        <span class="brand">NetLights <span class="pill">Linux</span></span>
        <div class="tabs">
          <button class="tab active" data-tab="graph">Graph</button>
          <button class="tab" data-tab="routes">Routes</button>
          <button class="tab" data-tab="interfaces">Interfaces</button>
          <button class="tab" data-tab="devices">Devices</button>
          <button class="tab" data-tab="dns">DNS</button>
        </div>
      </div>
      <div class="sub" id="hdr">connecting…</div>
      <div class="tab-content" data-tab="graph"><div id="graph"></div></div>
      <div class="tab-content" data-tab="routes" hidden><table id="routes"></table></div>
      <div class="tab-content" data-tab="interfaces" hidden><table id="ifaces"></table></div>
      <div class="tab-content" data-tab="devices" hidden><div class="empty">No external devices — USB / Thunderbolt collectors arrive in a later update.</div></div>
      <div class="tab-content" data-tab="dns" hidden><table id="dns"></table></div>
    <script>
    const $=id=>document.getElementById(id);
    document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{const t=b.dataset.tab;document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('.tab-content').forEach(c=>c.hidden=(c.dataset.tab!==t));});
    function cell(c,head){const e=document.createElement(head?'th':'td');if(c&&typeof c==='object'){e.innerHTML=c.html;e.className=c.cls||(c.mono?'mono':'');}else{e.textContent=c==null?'':c;}return e;}
    function fill(t,hs,rs){const el=$(t);el.innerHTML='';const h=document.createElement('tr');for(const x of hs)h.appendChild(cell(x,true));el.appendChild(h);for(const r of rs){const tr=document.createElement('tr');for(const x of r)tr.appendChild(cell(x,false));el.appendChild(tr);}}
    function bytes(n){n=Number(n||0);if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';if(n<1073741824)return (n/1048576).toFixed(1)+' MB';return (n/1073741824).toFixed(2)+' GB';}
    function rate(b){b=Number(b||0);if(b<1)return '—';if(b<1000)return Math.round(b)+' B/s';if(b<1e6)return (b/1000).toFixed(1)+' KB/s';return (b/1e6).toFixed(2)+' MB/s';}
    let prev={};
    function derive(s){const now=performance.now()/1000;const r={};for(const i of s.interfaces){const p=prev[i.id];let rx=0,tx=0;if(p){const dt=now-p.t;if(dt>0){rx=Math.max(0,(i.rxBytes-p.rx)/dt);tx=Math.max(0,(i.txBytes-p.tx)/dt);}}r[i.id]={rx:rx,tx:tx,active:(rx>2000||tx>2000)};prev[i.id]={rx:i.rxBytes,tx:i.txBytes,t:now};}return r;}
    function topo(s){return JSON.stringify([s.machineModel,s.interfaces.map(i=>i.id),s.routes.map(x=>[x.destination,x.gateway,x.interfaceName]),s.gateways.map(g=>g.id)]);}
    async function loadGraph(){try{$('graph').innerHTML=await(await fetch('/graph.svg',{cache:'no-store'})).text();}catch(e){}}
    let topoSig=null;
    async function tick(){try{
      const s=await(await fetch('/snapshot.json',{cache:'no-store'})).json();
      const r=derive(s);
      const ns=topo(s);if(ns!==topoSig){topoSig=ns;await loadGraph();}
      $('hdr').textContent=s.machineModel+'  ·  egress: '+(s.egress?(s.egress.viaInterface+' ('+s.egress.kind+')'):'—')+'  ·  '+s.interfaces.length+' interfaces';
      document.querySelectorAll('#graph path.wire').forEach(w=>{const id=w.getAttribute('data-iface');w.classList.toggle('active',!!(id&&r[id]&&r[id].active));});
      fill('ifaces',['','Interface','Type','IPv4','MAC','MTU','RX/s','TX/s','RX','TX'],s.interfaces.map(i=>[
        {html:'<span class="dot '+(i.linkState||'unknown')+'"></span>'},{html:i.id,mono:1},i.category,
        {html:(i.ipv4Addresses||[]).join(', '),mono:1},{html:i.macAddress||'—',mono:1},i.mtu,
        {html:rate(r[i.id]&&r[i.id].rx),cls:'mono rate'},{html:rate(r[i.id]&&r[i.id].tx),cls:'mono rate'},
        bytes(i.rxBytes),bytes(i.txBytes)]));
      fill('routes',['Destination','Gateway','Netmask','Interface','Flags'],s.routes.map(rt=>[
        {html:rt.destination,mono:1},{html:rt.gateway||'—',mono:1},{html:rt.netmask||'—',mono:1},{html:rt.interfaceName,mono:1},{html:rt.flags,mono:1}]));
      fill('dns',['Scope','Resolvers','Search'],(s.dnsConfigs||[]).map(d=>[
        d.scopeLabel,{html:(d.servers||[]).join('  '),mono:1},(d.searchDomains||[]).join(', ')]));
    }catch(e){$('hdr').textContent='error: '+e;}}
    tick();setInterval(tick,1000);
    </script></body></html>
    """
}
#endif
