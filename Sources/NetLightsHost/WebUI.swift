import Foundation

// The browser shell for `serve`: a tabbed layout mirroring the macOS app (Graph / Routes /
// Interfaces / Devices / DNS), polling /snapshot.json and re-fetching /graph.svg only when
// the topology signature changes, so the ant-crawl animation never restarts mid-stride.
extension WebServer {
    static func indexHTML(pollMS: Int) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>NetLights</title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          body{background:#0d1117;color:#c9d1d9;font:13px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:20px}
          .sub{color:#8b949e;margin-bottom:18px}
          table{border-collapse:collapse;width:100%;margin-bottom:22px}
          th,td{text-align:left;padding:5px 10px;border-bottom:1px solid #21262d;font-variant-numeric:tabular-nums}
          th{color:#8b949e;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
          .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
          .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
          .up{background:#3fb950}.down{background:#f85149}.unknown{background:#8b949e}
          .pill{background:#21262d;border-radius:10px;padding:1px 8px;font-size:11px;font-weight:400}
          .topbar{display:flex;align-items:center;gap:16px;margin-bottom:4px;flex-wrap:wrap}
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
          h3{font-size:12px;color:#58a6ff;text-transform:uppercase;letter-spacing:.05em;margin:18px 0 6px}
        </style></head><body>
          <div class="topbar">
            <span class="brand">NetLights</span>
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
          <div class="tab-content" data-tab="routes" hidden><div id="routesWrap"></div></div>
          <div class="tab-content" data-tab="interfaces" hidden><table id="ifaces"></table></div>
          <div class="tab-content" data-tab="devices" hidden><div id="devicesWrap"></div></div>
          <div class="tab-content" data-tab="dns" hidden><table id="dns"></table></div>
        <script>
        const $=id=>document.getElementById(id);
        document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{const t=b.dataset.tab;document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('.tab-content').forEach(c=>c.hidden=(c.dataset.tab!==t));});
        function cell(c,head){const e=document.createElement(head?'th':'td');if(c&&typeof c==='object'){e.innerHTML=c.html;e.className=c.cls||(c.mono?'mono':'');}else{e.textContent=c==null?'':c;}return e;}
        function table(hs,rs){const el=document.createElement('table');const h=document.createElement('tr');for(const x of hs)h.appendChild(cell(x,true));el.appendChild(h);for(const r of rs){const tr=document.createElement('tr');for(const x of r)tr.appendChild(cell(x,false));el.appendChild(tr);}return el;}
        function fill(t,hs,rs){const el=$(t);el.innerHTML='';const h=document.createElement('tr');for(const x of hs)h.appendChild(cell(x,true));el.appendChild(h);for(const r of rs){const tr=document.createElement('tr');for(const x of r)tr.appendChild(cell(x,false));el.appendChild(tr);}}
        function bytes(n){n=Number(n||0);if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';if(n<1073741824)return (n/1048576).toFixed(1)+' MB';return (n/1073741824).toFixed(2)+' GB';}
        // BITS per second, matching the app's on-wire numbers and the negotiated link speed.
        // (This used to report bytes/s here and bits/s in the app — the same link read
        // eight times slower in the browser.)
        function rate(bytesPerSec){const b=Number(bytesPerSec||0)*8;if(b<1000)return '—';if(b<1e6)return (b/1000).toFixed(0)+' Kbps';if(b<1e9)return (b/1e6).toFixed(1)+' Mbps';return (b/1e9).toFixed(2)+' Gbps';}
        let prev={};
        function derive(s){const now=performance.now()/1000;const r={};for(const i of s.interfaces){const p=prev[i.id];let rx=0,tx=0;if(p){const dt=now-p.t;if(dt>0.4&&dt<5){rx=Math.max(0,(i.rxBytes-p.rx)/dt);tx=Math.max(0,(i.txBytes-p.tx)/dt);}else if(p.rx!==undefined){rx=p.rxRate||0;tx=p.txRate||0;}}r[i.id]={rx:rx,tx:tx,active:(rx>1024||tx>1024)};prev[i.id]={rx:i.rxBytes,tx:i.txBytes,t:now,rxRate:rx,txRate:tx};}return r;}
        function topo(s){return JSON.stringify([s.machineModel,s.interfaces.map(i=>i.id),s.routes.map(x=>[x.destination,x.gateway,x.interfaceName]),s.gateways.map(g=>g.id)]);}
        async function loadGraph(){try{$('graph').innerHTML=await(await fetch('/graph.svg',{cache:'no-store'})).text();}catch(e){}}
        function routeRows(rs){return rs.map(rt=>[{html:rt.destination+(rt.isDefault?' ✦':''),mono:1},{html:rt.gateway||'—',mono:1},{html:rt.netmask||'—',mono:1},{html:rt.interfaceName,mono:1},{html:rt.flags,mono:1}]);}
        const RH=['Destination','Gateway','Netmask','Interface','Flags'];
        let topoSig=null;
        async function tick(){try{
          const s=await(await fetch('/snapshot.json',{cache:'no-store'})).json();
          const r=derive(s);
          const ns=topo(s);if(ns!==topoSig){topoSig=ns;await loadGraph();}
          const up=s.interfaces.filter(i=>i.linkState==='up').length;
          $('hdr').textContent=(s.machineModel||'')+'  ·  egress: '+(s.egress?(s.egress.viaInterface+' ('+s.egress.kind+')'):'—')+'  ·  '+up+'/'+s.interfaces.length+' up';
          document.querySelectorAll('#graph path.wire').forEach(w=>{const id=w.getAttribute('data-iface');w.classList.toggle('active',!!(id&&r[id]&&r[id].active));});
          fill('ifaces',['','Interface','Type','IPv4','MAC','MTU','RX/s','TX/s','RX','TX'],s.interfaces.map(i=>[
            {html:'<span class="dot '+(i.linkState||'unknown')+'"></span>'},{html:i.id,mono:1},i.category,
            {html:(i.ipv4Addresses||[]).join(', '),mono:1},{html:i.macAddress||'—',mono:1},i.mtu,
            {html:rate(r[i.id]&&r[i.id].rx),cls:'mono rate'},{html:rate(r[i.id]&&r[i.id].tx),cls:'mono rate'},
            bytes(i.rxBytes),bytes(i.txBytes)]));
          // Routes, grouped the way the app groups them.
          const tun=new Set((s.gateways||[]).filter(g=>g.isVPN).flatMap(g=>g.reachableVia||[]));
          const enc=[],dir=[],loc=[];
          for(const rt of s.routes){const pub=/^(\\d+)\\./.test(rt.destination)&&!/^(10\\.|127\\.|192\\.168\\.|172\\.(1[6-9]|2\\d|3[01])\\.)/.test(rt.destination);
            if(tun.has(rt.interfaceName))enc.push(rt);else if(pub&&!rt.isDefault)dir.push(rt);else loc.push(rt);}
          const rw=$('routesWrap');rw.innerHTML='';
          for(const [t,list] of [['Direct — split-tunnel (unencrypted)',dir],['Encrypted — VPN tunnel',enc],['Local',loc]]){
            if(!list.length)continue;const h=document.createElement('h3');h.textContent=t;rw.appendChild(h);rw.appendChild(table(RH,routeRows(list)));}
          const dw=$('devicesWrap');
          if(!(s.attachedDevices||[]).length){dw.innerHTML='<div class="empty">No external devices — USB / Thunderbolt collectors arrive in a later update.</div>';}
          else{dw.innerHTML='';dw.appendChild(table(['Device','Type','Vendor','Bus','Speed'],s.attachedDevices.map(d=>[d.name,d.kind,d.vendorName||'—',d.connection||'—',{html:(d.detail||'—'),mono:1}])));}
          fill('dns',['Scope','Interface','Resolvers','Search'],(s.dnsConfigs||[]).map(d=>[
            d.scopeLabel,{html:d.interfaceName||'—',mono:1},{html:(d.servers||[]).join('  '),mono:1},(d.searchDomains||[]).join(', ')]));
        }catch(e){$('hdr').textContent='error: '+e;}}
        tick();setInterval(tick,\(pollMS));
        </script></body></html>
        """
    }
}
