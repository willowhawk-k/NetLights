import Foundation

// The browser shell for `serve`: a tabbed layout mirroring the macOS app (Graph / Routes /
// Interfaces / Devices / DNS), plus the two controls the app and the TUI have and this
// didn't — Privacy and Hide inactive.
//
// Both controls are SERVER-side (`?privacy=1&hide=1`). For hide-inactive that's forced: the
// graph is server-rendered SVG, so only the layout engine can drop nodes. For privacy it is
// the stronger choice anyway — `serve` has no authentication, so masking before the response
// is written means the real addresses never cross the wire at all, rather than relying on
// the page not to render them.
//
// The tables are drawn straight from /ui.json, whose cells Swift has already formatted. This
// page used to rebuild them from the raw snapshot with its own JS reimplementations of
// speedLabel/connectionLabel/classLabel/the rate formatter/the route classifier, and every
// one of them had drifted from the Swift original (see WebPresentation.swift).
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
          .topbar{display:flex;align-items:center;gap:16px;margin-bottom:4px;flex-wrap:wrap}
          .brand{font-size:16px;font-weight:600}
          .tabs{display:flex;gap:2px;background:#161b22;border-radius:8px;padding:3px}
          .tab{background:none;border:none;color:#8b949e;font:inherit;font-size:13px;padding:5px 15px;border-radius:6px;cursor:pointer}
          .tab.active{background:#0d1117;color:#e6edf3}
          .toggles{display:flex;gap:8px;margin-left:auto}
          .toggle{background:#161b22;border:1px solid #21262d;color:#8b949e;font:inherit;font-size:12px;
                  padding:5px 12px;border-radius:6px;cursor:pointer}
          .toggle:hover{border-color:#30363d;color:#c9d1d9}
          .toggle.on{background:#1f6feb22;border-color:#1f6feb;color:#58a6ff}
          .tab-content[hidden]{display:none}
          .empty{color:#8b949e;padding:40px;text-align:center}
          .banner{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:10px 14px;
                  margin-bottom:16px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:#39c5cf}
          #graph{overflow:auto;border:1px solid #21262d;border-radius:8px}
          @keyframes antcrawl{to{stroke-dashoffset:-20}}
          #graph path.wire.active{stroke-dasharray:6 5;animation:antcrawl .55s linear infinite}
          #graph g{cursor:default}
          td.rate{color:#3fb950}
          td.idle{color:#6e7681}
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
            <div class="toggles">
              <button class="toggle" id="hideBtn" title="Hide interfaces with no link and no traffic (h)">Hide inactive</button>
              <button class="toggle" id="privBtn" title="Mask IP / MAC addresses, SSIDs and search domains (p)">Privacy</button>
            </div>
          </div>
          <div class="sub" id="hdr">connecting…</div>
          <div class="tab-content" data-tab="graph"><div id="graph"></div></div>
          <div class="tab-content" data-tab="routes" hidden><div id="routesWrap"></div></div>
          <div class="tab-content" data-tab="interfaces" hidden><div id="ifacesWrap"></div></div>
          <div class="tab-content" data-tab="devices" hidden><div id="devicesWrap"></div></div>
          <div class="tab-content" data-tab="dns" hidden><div id="dnsWrap"></div></div>
        <script>
        const $=id=>document.getElementById(id);
        document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{const t=b.dataset.tab;document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('.tab-content').forEach(c=>c.hidden=(c.dataset.tab!==t));});

        // Both flags live in the URL, so a masked view can be bookmarked or handed to
        // someone else and stays masked.
        const url=new URL(location.href);
        let privacy=url.searchParams.get('privacy')==='1';
        let hide=url.searchParams.get('hide')==='1';
        function paintToggles(){
          $('privBtn').classList.toggle('on',privacy);
          $('hideBtn').classList.toggle('on',hide);
          const u=new URL(location.href);
          privacy?u.searchParams.set('privacy','1'):u.searchParams.delete('privacy');
          hide?u.searchParams.set('hide','1'):u.searchParams.delete('hide');
          history.replaceState(null,'',u);
        }
        function flags(){return (privacy?'&privacy=1':'')+(hide?'&hide=1':'');}
        $('privBtn').onclick=()=>{privacy=!privacy;paintToggles();topoSig=null;tick();};
        $('hideBtn').onclick=()=>{hide=!hide;paintToggles();topoSig=null;tick();};
        // Same keys as the TUI.
        document.addEventListener('keydown',e=>{
          if(e.metaKey||e.ctrlKey||e.altKey)return;
          if(e.key==='p'){privacy=!privacy;paintToggles();topoSig=null;tick();}
          if(e.key==='h'){hide=!hide;paintToggles();topoSig=null;tick();}
        });
        paintToggles();

        // Everything below renders PRE-FORMATTED cells. No formatters, no classifiers, no
        // masking in JS — those all live in Swift now, so the browser can't drift from the
        // app. Cells go in via textContent, which is also why no escaping helper is needed:
        // snapshot strings are attacker-influenced (USB product strings, SSIDs, DHCP search
        // domains) and textContent never interprets them as markup.
        function table(cols,rows){
          const el=document.createElement('table');
          const h=document.createElement('tr');
          for(const c of cols){const th=document.createElement('th');th.textContent=c;h.appendChild(th);}
          el.appendChild(h);
          for(const r of rows){
            const tr=document.createElement('tr');
            let cells=r.cells;
            // A leading blank column header means "status dot here".
            if(cols[0]===''){
              const td=document.createElement('td');
              const s=document.createElement('span');
              s.className='dot '+(r.state||'unknown');
              td.appendChild(s);tr.appendChild(td);
            }
            cells.forEach((v,i)=>{
              const td=document.createElement('td');
              td.textContent=(r.depth&&i===0?'\\u00a0\\u00a0\\u00a0\\u00a0'.repeat(r.depth):'')+v;
              td.className='mono';
              // RX/s and TX/s in the interfaces table.
              if(cols[0]===''&&(i===7||i===8))td.className='mono '+(r.active?'rate':'idle');
              tr.appendChild(td);
            });
            el.appendChild(tr);
          }
          return el;
        }
        function fillSections(wrap,sections,emptyMsg){
          const el=$(wrap);el.innerHTML='';
          if(!sections||!sections.length){
            const d=document.createElement('div');d.className='empty';
            d.textContent=emptyMsg||'Nothing to show.';el.appendChild(d);return;
          }
          for(const s of sections){
            if(s.title){const h=document.createElement('h3');h.textContent=s.title;el.appendChild(h);}
            el.appendChild(table(s.columns,s.rows));
          }
        }

        // The graph is laid out for the ACTUAL viewport, the way the app's GeometryReader
        // drives the SwiftUI graph — it used to be frozen at a hard-coded 1200x760 canvas.
        function graphDims(){
          const el=$('graph');
          return 'w='+Math.max(640,Math.round(el.clientWidth||window.innerWidth-40))
               +'&h='+Math.max(480,Math.round(window.innerHeight-160));
        }
        let topoSig=null,lastDims='';
        async function loadGraph(){
          try{lastDims=graphDims();
              $('graph').innerHTML=await(await fetch('/graph.svg?'+lastDims+flags(),{cache:'no-store'})).text();}
          catch(e){}
        }
        let resizeTimer=null;
        window.addEventListener('resize',()=>{
          clearTimeout(resizeTimer);
          resizeTimer=setTimeout(()=>{if(graphDims()!==lastDims)loadGraph();},250);
        });

        async function tick(){try{
          const u=await(await fetch('/ui.json?_='+Date.now()+flags(),{cache:'no-store'})).json();
          $('hdr').textContent=u.header;
          // Re-fetch the SVG only when the topology or the view flags change, so the
          // ant-crawl animation never restarts mid-stride.
          // Everything the GRAPH draws has to be in this signature, not just the interface
          // list: hardware, routes and gateways all change the picture. Keying on interface
          // ids alone meant plugging in a dock or failing over the default route updated the
          // tables beside the graph while the graph itself silently kept the old topology.
          const sig=JSON.stringify([
            u.interfaces.rows.map(r=>r.cells[0]),
            u.devices.flatMap(s=>s.rows.map(r=>r.cells[0]+'|'+r.cells[7])),
            u.routes.flatMap(s=>s.rows.map(r=>r.cells[0]+'|'+r.cells[1]+'|'+r.cells[3])),
            u.header, privacy, hide]);
          if(sig!==topoSig){topoSig=sig;await loadGraph();}
          const active=new Set(u.activeInterfaces||[]);
          document.querySelectorAll('#graph path.wire').forEach(w=>{
            const id=w.getAttribute('data-iface');
            w.classList.toggle('active',!!(id&&active.has(id)));
          });
          fillSections('ifacesWrap',[u.interfaces],'No interfaces.');
          fillSections('routesWrap',u.routes,'No routes.');
          fillSections('devicesWrap',u.devices,u.deviceEmptyMessage);
          const dw=$('dnsWrap');dw.innerHTML='';
          if(u.dnsBanner){const b=document.createElement('div');b.className='banner';b.textContent=u.dnsBanner;dw.appendChild(b);}
          if(u.dns&&u.dns.length){for(const s of u.dns)dw.appendChild(table(s.columns,s.rows));}
          else if(!u.dnsBanner){const d=document.createElement('div');d.className='empty';
                                d.textContent='No DNS configuration reported.';dw.appendChild(d);}
        }catch(e){$('hdr').textContent='error: '+e;}}
        tick();setInterval(tick,\(pollMS));
        </script></body></html>
        """
    }
}
