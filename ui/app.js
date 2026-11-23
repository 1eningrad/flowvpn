const API='/cgi-bin/eclipvpn';
let state={},pings={},currentLogFilter='conn',incidentStats={};

const TOAST_ICONS={
  success:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l5 5L20 7"/></svg>',
  error:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M15 9l-6 6M9 9l6 6"/></svg>',
  info:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/></svg>',
  warning:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3L2 20h20L12 3z"/><path d="M12 10v4M12 17h.01"/></svg>',
  loading:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><circle cx="12" cy="12" r="9" stroke-dasharray="40 16"/></svg>'
};
const TOAST_CLOSE='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M6 6l12 12M6 18L18 6"/></svg>';
let _toastId=0;
function toast(msg,opts){
  if(typeof opts==='string')opts={type:opts};
  opts=opts||{};
  const type=opts.type||'info';
  const duration=opts.duration!==undefined?opts.duration:(type==='error'?4500:type==='loading'?0:2800);
  const id='t'+(++_toastId);
  const container=document.getElementById('toasts');
  if(!container)return id;
  const el=document.createElement('div');
  el.className='toast '+type;
  el.id=id;
  const iconCls='toast-icon'+(type==='loading'?' spin':'');
  const titleEsc=esc(typeof msg==='string'?msg:(msg.title||''));
  // desc comes either as toast({title,desc}) or as updateToast(id,msg,{desc}).
  const descEsc=esc((msg&&msg.desc)||(opts&&opts.desc)||'');
  el.innerHTML=
    '<div class="'+iconCls+'">'+TOAST_ICONS[type]+'</div>'+
    '<div class="toast-body"><div class="toast-title">'+titleEsc+'</div>'+
    (descEsc?'<div class="toast-desc">'+descEsc+'</div>':'')+'</div>'+
    '<div class="toast-close" onclick="dismissToast(\''+id+'\')">'+TOAST_CLOSE+'</div>';
  container.appendChild(el);
  requestAnimationFrame(()=>el.classList.add('show'));
  if(duration>0)setTimeout(()=>dismissToast(id),duration);
  return id;
}
function dismissToast(id){
  const el=document.getElementById(id);
  if(!el)return;
  el.classList.remove('show');el.classList.add('hide');
  setTimeout(()=>{if(el.parentNode)el.parentNode.removeChild(el)},250);
}
function updateToast(id,msg,opts){
  dismissToast(id);
  return toast(msg,opts);
}
toast.success=(m,d)=>toast(d?{title:m,desc:d}:m,'success');
toast.error=(m,d)=>toast(d?{title:m,desc:d}:m,'error');
toast.info=(m,d)=>toast(d?{title:m,desc:d}:m,'info');
toast.loading=(m)=>toast(m,{type:'loading',duration:0});
function fmtUp(s){if(!s||s<=0)return'—';s=Math.floor(s);const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);if(d>0)return d+' дн '+h+' ч';if(h>0)return h+' ч '+m+' мин';if(m>0)return m+' мин';return s+' сек'}
function _pad(n){return(n<10?'0':'')+n}
// Stopwatch format for the live session timer — always shows seconds so it
// visibly ticks every second: "5:07" → "1:23:45" → "2д 3:04:09".
function fmtUpLive(s){if(!s||s<=0)return'—';s=Math.floor(s);const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60),sec=s%60;if(d>0)return d+'д '+h+':'+_pad(m)+':'+_pad(sec);if(h>0)return h+':'+_pad(m)+':'+_pad(sec);return m+':'+_pad(sec)}
// Live uptime ticker: between status polls, count up locally from the last
// fetched value so the session timer advances every second instead of
// jumping on each poll. _uptimeBase is refreshed in fetchStatus.
let _uptimeBase=null;
function _tickUptime(){
  if(!_uptimeBase)return;
  const cur=_uptimeBase.sec+Math.floor((Date.now()-_uptimeBase.at)/1000);
  const t=fmtUpLive(cur);
  const a=document.getElementById('uptimeLive');if(a&&a.textContent!==t)a.textContent=t;
}
setInterval(_tickUptime,1000);
// Human-readable "X ago" for unix timestamps. Used in watchdog toast so
// the user knows whether the announcement is from 5 min ago or last night.
function fmtAgo(ts){
  if(!ts)return '';
  const diff=Math.floor(Date.now()/1000-ts);
  if(diff<60)return 'только что';
  if(diff<3600)return Math.floor(diff/60)+' мин назад';
  if(diff<86400){
    const h=Math.floor(diff/3600);
    return h+' '+(h===1?'час':h<5?'часа':'часов')+' назад';
  }
  const d=new Date(ts*1000);
  const days=Math.floor(diff/86400);
  if(days===1)return 'вчера в '+d.toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'});
  return days+' дн. назад';
}
function fmtBytes(b){b=+b||0;if(b<1024)return b.toFixed(0)+' Б';if(b<1048576)return(b/1024).toFixed(1)+' КБ';if(b<1073741824)return(b/1048576).toFixed(2)+' МБ';if(b<1099511627776)return(b/1073741824).toFixed(2)+' ГБ';return(b/1099511627776).toFixed(2)+' ТБ'}

// Mask a subscription URL for display — keep the host + a short token tail,
// hide the credential middle (the path token IS the panel credential).
function maskUrl(u){
  if(!u)return '';
  // A manual-server URI carries credentials (uuid/password) before the @ —
  // show only scheme + host:port, never a prefix slice of the secret.
  const p=String(u).match(/^(vless|vmess|trojan|ss|hysteria2|hy2):\/\//i);
  if(p){const h=String(u).match(/^[a-z0-9]+:\/\/[^@\s]*@([^/?#\s]*)/i);return p[1]+'://…'+(h?('@'+h[1]):'');}
  const m=String(u).match(/^https?:\/\/([^/]+)(\/.*)?$/i);
  if(!m)return u.length>30?u.slice(0,26)+'…':u;
  const host=m[1], path=(m[2]||'').replace(/\/+$/,'');
  const tail=path.slice(-6);
  return host+(path?('/…'+tail):'');
}
// Compact one-line quota / expiry summary for a subscription row. "" if no meta.
function subQuotaLine(m){
  if(!m||!m.fetched_at)return '';
  const NOW=Math.floor(Date.now()/1000);
  const total=+m.total||0, used=(+m.upload||0)+(+m.download||0);
  const totalUnl=total>1099511627776*100;  // >100TB → unlimited tariff
  const parts=[];
  if(totalUnl){ if(used>0)parts.push(fmtBytes(used)+' · безлимит'); }
  else if(total>0){ const pct=Math.min(100,Math.round(used/total*100)); parts.push(fmtBytes(used)+' / '+fmtBytes(total)+' ('+pct+'%)'); }
  else if(used>0){ parts.push(fmtBytes(used)); }
  const expire=+m.expire||0;
  if(expire>0 && expire<NOW+86400*3650){           // skip "fake-infinite" expiries
    const left=expire-NOW;
    parts.push(left<0?'⚠ срок истёк':(Math.floor(left/86400)+' дн.'));
  }
  return parts.join(' · ');
}
// Render the list of subscriptions (Settings ▸ Подписки). Per-sub server count
// comes from the merged servers list (state.servers tagged with sub_id); quota/
// expiry from state.subscription_meta (keyed by sub_id). The «Обновить» button
// lives in the static card head now, so this innerHTML rebuild can't detach it.
function renderSubscriptions(){
  const el=document.getElementById('subList');
  if(!el)return;
  if(_subActionPending||_updatePending)return;   // don't clobber a row mid-action
  const subs=(state&&state.subscriptions)||[];
  const metaMap=(state&&state.subscription_meta)||{};
  const counts={};
  ((state&&state.servers)||[]).forEach(s=>{const k=s.sub_id||'';counts[k]=(counts[k]||0)+1});
  if(!subs.length){const b=document.getElementById('addSubBox');if(b)b.open=true;el.innerHTML='<div style="color:var(--text-dim);font-size:12px;padding:6px 0">Пока нет подписок — добавьте первую ниже.</div>';return}
  el.innerHTML=subs.map(sub=>{
    const m=metaMap[sub.id]||{};
    const cnt=counts[sub.id]||0;
    const en=sub.enabled!==false;
    const q=subQuotaLine(m);
    // Only the hex id goes into the inline handlers — the (free-text) name is
    // looked up from state in subRename/subRemove, sidestepping nested-quote
    // escaping in the onclick="…('…')" attribute.
    return '<div class="sub-card" style="display:flex;align-items:center;gap:10px;padding:10px;border:1px solid var(--card-border,rgba(255,255,255,.07));border-radius:10px;margin-bottom:8px;'+(en?'':'opacity:.5;')+'">'
      +'<div style="flex:1;min-width:0">'
        +'<div style="font-size:13.5px;font-weight:600;display:flex;align-items:center;gap:8px">'+esc(sub.name||'Подписка')
          +'<span style="font-size:11px;font-weight:500;color:var(--text-dim);background:var(--card-hover);padding:1px 7px;border-radius:10px;flex-shrink:0">'+plural(cnt,'сервер','сервера','серверов')+'</span></div>'
        +'<div style="font-size:11.5px;color:var(--text-dim);margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+esc(maskUrl(sub.url))+'</div>'
        +(q?'<div style="font-size:11.5px;color:var(--text-muted);margin-top:2px">'+esc(q)+'</div>':'')
        +(m.announce?'<div style="font-size:11.5px;color:var(--text);margin-top:8px;padding:8px;background:var(--card-hover);border-radius:8px;white-space:pre-line;line-height:1.4">'+esc(m.announce)+'</div>':'')
      +'</div>'
      +'<div style="display:flex;align-items:center;gap:4px;flex-shrink:0">'
        +'<label class="toggle toggle-sm" title="'+(en?'Выключить':'Включить')+' подписку"><input type="checkbox" '+(en?'checked':'')+' onchange="subToggle(\''+sub.id+'\',this.checked)"><div class="toggle-track"></div><div class="toggle-knob"></div></label>'
        +'<button class="btn btn-ghost btn-sm sub-btn" title="Переименовать" aria-label="Переименовать" onclick="subRename(\''+sub.id+'\')"><svg class="icon icon-sm"><use href="#i-edit"/></svg></button>'
        +'<button class="btn btn-ghost btn-sm sub-btn" title="Удалить" aria-label="Удалить" onclick="subRemove(\''+sub.id+'\')"><svg class="icon icon-sm"><use href="#i-x"/></svg></button>'
      +'</div>'
    +'</div>';
  }).join('');
}
function fmtSpeed(bps){bps=+bps||0;if(bps<1024)return bps.toFixed(0)+' Б/с';if(bps<1048576)return(bps/1024).toFixed(1)+' КБ/с';return(bps/1048576).toFixed(2)+' МБ/с'}
function plural(n,one,few,many){const a=n%10,b=n%100;return n+' '+(a===1&&b!==11?one:a>=2&&a<=4&&(b<12||b>14)?few:many)}
function esc(s){if(!s)return'';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;')}
// Last measured RTT per server, kept in this browser so the list isn't all «—»
// after a reload. Keyed by host|port (indices shift); shown dimmed until re-measured.
let _savedPings={};
try{_savedPings=JSON.parse(localStorage.getItem('eclipvpn.pings')||'{}')||{}}catch(e){}
function _pingKey(i){const s=(state.servers||[])[i];return s?s.host+'|'+s.port:''}
function storePings(list){
  const now=Math.floor(Date.now()/1000);
  list.forEach(x=>{pings[x.index]=x.ping;const k=_pingKey(x.index);if(k)_savedPings[k]=[x.ping,now]});
  for(const k in _savedPings)if(now-_savedPings[k][1]>7*86400)delete _savedPings[k];
  try{localStorage.setItem('eclipvpn.pings',JSON.stringify(_savedPings))}catch(e){}
}
function pingClass(ms){return ms<0?'ping-none':ms<150?'ping-good':ms<400?'ping-mid':'ping-bad'}

function showTab(name,el){
  // «Главная» exists only in the bottom nav. It has no .section: the desktop
  // section stays selected underneath, so widening the window still shows it.
  document.body.classList.toggle('m-home',name==='home');
  if(name==='home'){
    document.querySelectorAll('.bn-item').forEach(t=>{
      const on=t.dataset.tab==='home';
      t.classList.toggle('active',on);
      if(on)t.setAttribute('aria-current','page');else t.removeAttribute('aria-current');
    });
    stopLive();
    window.scrollTo(0,0);
    if(window._setCompact)window._setCompact();
    return;
  }
  document.querySelectorAll('.section').forEach(s=>s.classList.remove('active'));
  document.querySelectorAll('.tab,.bn-item').forEach(t=>{t.classList.remove('active');t.removeAttribute('aria-current')});
  document.getElementById('sec-'+name).classList.add('active');
  document.querySelectorAll('.tab[data-tab="'+name+'"],.bn-item[data-tab="'+name+'"]').forEach(e=>{
    e.classList.add('active');
    e.setAttribute('aria-current','page');
  });
  stopLive();
  if(name==='devices')loadDevices();
  if(name==='logs'){loadLogs();if(liveMode)startLive()}
  if(name==='routing'){loadDomains();loadPresets();}
  if(name==='settings'){loadSchedule();loadAutoUpdate();loadSystemInfo();resumeUpdate()}
  // Phone: each tab is its own screen — start at its top. Desktop stays in place.
  if(window.matchMedia('(max-width:840px)').matches)window.scrollTo(0,0);
  if(window._setCompact)window._setCompact();
}
function showTabMobile(name){
  const desktopTab=document.querySelector('.tabs .tab[data-tab="'+name+'"]');
  showTab(name,desktopTab||document.createElement('div'));
}
// Jump to Settings ▸ Подписки and focus the URL field so the user can paste a
// subscription link immediately. Used by the empty-server-list hint when there
// are no subscriptions configured.
function goToAutomation(){
  showTabMobile('settings');
  const c=document.getElementById('automationCard');
  const y=c.getBoundingClientRect().top+window.pageYOffset-document.getElementById('appHeader').offsetHeight-12;
  window.scrollTo({top:Math.max(0,y)});
}
function goToSubscriptions(){
  showTabMobile('settings');
  document.getElementById('addSubBox').open=true;
  setTimeout(function(){var i=document.getElementById('subUrl');if(i){i.scrollIntoView({behavior:'smooth',block:'center'});try{i.focus()}catch(e){}}},120);
}

// Windows / Chrome on Windows / Brave-on-Windows / некоторые Linux distros
// don't render flag emoji at all — Segoe UI Emoji (Windows) deliberately
// strips the regional-indicator pairs. We probe with a canvas: render a
// known flag emoji (🇫🇮 = blue cross on white), check if any actually-blue
// pixel landed. If not, swap flag emoji for a 2-letter country code badge
// in renderServers / wherever else flags appear.
const FLAG_SUPPORT = (function(){
  try{
    const c=document.createElement('canvas');
    c.width=20;c.height=20;
    const ctx=c.getContext('2d');
    ctx.font='16px sans-serif';
    ctx.fillText('🇫🇮',0,16);  // 🇫🇮
    const d=ctx.getImageData(0,0,20,20).data;
    for(let i=0;i<d.length;i+=4){
      // Look for a noticeably blue pixel — Finland flag's blue cross.
      if(d[i+2]>120&&d[i]<80&&d[i+1]<140)return true;
    }
    return false;
  }catch(_){return false}
})();

// Convert a flag emoji (regional indicator pair) to its ISO 3166-1 alpha-2
// code. 🇫🇮 → "FI". Returns empty string on no match.
function emojiToCountryCode(s){
  if(!s)return '';
  const m=s.match(/[\u{1F1E6}-\u{1F1FF}][\u{1F1E6}-\u{1F1FF}]/u);
  if(!m)return '';
  // RI-A is U+1F1E6 and maps to "A" (65). The old code subtracted 0x1F1A5
  // AND added 64 — applying the offset twice landed in C1 control chars,
  // so the Windows fallback badge rendered invisible garbage instead of "FI".
  const a=m[0].codePointAt(0)-0x1F1E6;
  const b=m[0].codePointAt(2)-0x1F1E6;
  return String.fromCharCode(65+a)+String.fromCharCode(65+b);
}

// Render a flag for a server name. Returns either:
//   - <span class="server-flag">🇫🇮</span>      — when emoji rendering works
//   - <span class="country-code">FI</span>      — when it doesn't (Windows)
function flagHTML(name){
  const m=(name||'').match(/^(\p{RI}\p{RI})/u);
  if(!m)return '';
  if(FLAG_SUPPORT){
    return '<span class="server-flag">'+esc(m[1])+'</span>';
  }
  const code=emojiToCountryCode(m[1]);
  return '<span class="country-code">'+esc(code||'??')+'</span>';
}

// Full server-name display (flag + name) — for headers, badges, anywhere
// the user sees a server name. Strips the regional indicator pair from
// the name and renders it via flagHTML so the fallback works there too.
function serverNameDisplay(name){
  if(!name)return '—';
  const m=name.match(/^(\p{RI}\p{RI})\s*(.*)/u);
  if(!m)return esc(name);
  const f=flagHTML(name);
  return f + ' ' + esc(m[2]);
}

function isMeteredServer(name){
  // Must match _is_metered_server() in /usr/bin/eclipvpn
  return /МТС|мтс|MTS|mts|Т2|т2|Tele2|tele2|\bБи\b|Билайн|билайн|Beeline|beeline|Мегафон|мегафон|Megafon|megafon/.test(name||'');
}

// Collapsed provider groups, keyed by sub_id, persisted so the choice survives
// reloads. Lets a big multi-subscription pool (e.g. a 162-server provider) be
// folded away to its header.
let _collapsedSubs = new Set((function(){try{return JSON.parse(localStorage.getItem('eclipvpn-collapsed-subs')||'[]')}catch(e){return[]}})());
function toggleSubGroup(key){
  if(_collapsedSubs.has(key)) _collapsedSubs.delete(key); else _collapsedSubs.add(key);
  try{localStorage.setItem('eclipvpn-collapsed-subs',JSON.stringify([..._collapsedSubs]))}catch(e){}
  if(state&&state.servers)renderServers(state.servers,state.selected);
}
function renderServers(servers,sel,switchingIdx){
  // The protocol tag only helps when the list mixes protocols.
  const mixedProto=new Set((servers||[]).map(x=>x.protocol||'vless')).size>1;
  const el=document.getElementById('serverList');
  if(!servers||!servers.length){
    // 0 servers means one of two very different things: subscriptions exist but
    // the fetch hasn't populated the pool yet (loading / panel blocked), OR there
    // are NO subscriptions at all (config reset, or the last sub was removed) —
    // in which case the tunnel may still be live off its already-generated config
    // while the list looks mysteriously empty. Distinguish via state.subscriptions
    // (only once /status has actually returned the array, to avoid a load flash)
    // so the no-subs case gets an actionable hint, not a dead-end message.
    const noSubs=state&&Array.isArray(state.subscriptions)&&state.subscriptions.length===0;
    el.innerHTML=noSubs
      ? '<div style="color:var(--text-dim);font-size:12.5px;padding:18px 14px;text-align:center;line-height:1.5">Нет активных подписок — список серверов пуст.<br>Добавьте подписку, чтобы серверы появились.<div style="margin-top:12px"><button class="btn btn-primary btn-sm" onclick="goToSubscriptions()">Добавить подписку</button></div></div>'
      : '<div style="color:var(--text-dim);font-size:12px;padding:16px;text-align:center">Серверы не загружены</div>';
    return;
  }
  // Group by provider when servers come from >1 subscription (single provider
  // needs no header). Key on the stable sub_id; servers are contiguous per sub.
  // A collapsed group renders only its header — its rows are dropped from the
  // DOM (keeps a 100s-server pool light), with a dot if the active server hides
  // inside it.
  const gkey=s=>(s.sub_id||s.sub_name||'');
  const provset={};servers.forEach(s=>{provset[gkey(s)]=1});
  const showGroups=Object.keys(provset).length>1;
  const counts={};servers.forEach(s=>{const k=gkey(s);counts[k]=(counts[k]||0)+1});
  const activeKey=(sel!=null&&servers[sel])?gkey(servers[sel]):null;
  let curKey=null, html='';
  servers.forEach((s,i)=>{
    const key=gkey(s);
    if(showGroups&&key!==curKey){
      curKey=key;
      const collapsed=_collapsedSubs.has(key);
      const dot=(collapsed&&key===activeKey)?'<span class="sgh-active" title="Активный сервер в этой свёрнутой группе"></span>':'';
      // key falls back to the free-text sub_name when sub_id is absent, so it
      // must NOT be spliced into the onclick JS string (esc() can't help there:
      // the attribute is entity-decoded before the JS parses, so &#39; breaks
      // out again). Carry it in a data-* attribute and read it back instead.
      html+='<div class="sub-group-head" data-key="'+esc(key)+'" onclick="toggleSubGroup(this.dataset.key)" role="button" tabindex="0" aria-expanded="'+(collapsed?'false':'true')+'" title="'+(collapsed?'Развернуть':'Свернуть')+'">'
        +'<span class="sgh-chev">'+(collapsed?'▸':'▾')+'</span>'
        +'<span>'+esc(s.sub_name||'Подписка')+'</span>'
        +'<span class="sgh-count">'+(counts[key]||0)+'</span>'+dot+'</div>';
    }
    if(showGroups&&_collapsedSubs.has(key))return;   // collapsed group → skip rows
    const a=i===sel?' active':'';
    const sw=i===switchingIdx?' switching':'';
    const saved=pings[i]===undefined?_savedPings[s.host+'|'+s.port]:null;
    const p=saved?saved[0]:pings[i];
    const pingStr=p!==undefined?(p<0?'нет':p+' мс'):'—';
    const cls=p!==undefined?pingClass(p)+(saved?' ping-old':''):'ping-none';
    const flagMatch=s.name.match(/^(\p{RI}\p{RI})\s*(.*)/u);
    const name=flagMatch?flagMatch[2]:s.name;
    const flagBadge=flagHTML(s.name);
    const bars='<span class="ping-bars"><span></span><span></span><span></span><span></span></span>';
    // metered still drives the row tint (.server-metered) — the "Тариф" badge it
    // used to render was dropped as noise; the tooltip on the row and the tint
    // carry it.
    const metered=isMeteredServer(s.name);
    // s.muted comes from /status (computed server-side against muted_servers) —
    // NOT recomputed here. isMeteredServer above already duplicates backend
    // logic in JS and that duplication has drifted before; don't add a second.
    const muted=!!s.muted;
    const muteBtn=`<span class="server-mute" onclick="toggleMute(event,${i},${muted})" role="button" tabindex="0"
      title="${muted?'Исключён из автовыбора. Нажмите, чтобы вернуть.':'Исключить из автовыбора (вручную останется доступен).'}"
      aria-label="${muted?'Вернуть в автовыбор':'Исключить из автовыбора'}"><svg class="icon icon-sm"><use href="#i-no-auto"/></svg></span>`;
    const protoLabels={vless:'VLESS',vmess:'VMess',trojan:'Trojan',shadowsocks:'SS',hysteria2:'HY2'};
    const proto=(s.protocol||'vless');
    const protoTag=!mixedProto?'':`<span class="server-proto" title="Протокол: ${esc(proto)}">${protoLabels[proto]||esc(proto)}</span>`;
    const inc=s.host?incidentStats[s.host]:null;
    const failTag=inc&&inc.count_24h>0
      ?`<span class="server-fail${inc.count_24h<=2?' warn':''}" title="Сбоев за 24ч: ${inc.count_24h}, за 7дн: ${inc.count_7d}. Подробности: Журнал → События.">⚠ ${inc.count_24h}</span>`
      :'';
    html+=`<div class="server${a}${sw}${metered?' server-metered':''}${muted?' server-muted':''}" onclick="selectServer(${i})" tabindex="0" role="button" aria-label="${esc(name)}${p!==undefined?(', пинг '+pingStr):''}${i===sel?', выбран':''}${muted?', исключён из автовыбора':''}${inc&&inc.count_24h>0?', сбоев за 24ч '+inc.count_24h:''}">
      ${flagBadge}
      <span class="server-name">${esc(name)}</span>
      ${protoTag}
      ${failTag}
      ${muteBtn}
      <span class="server-ping-box ${cls}" title="${saved?'Замер '+fmtAgo(saved[1]):'Время отклика сервера'}">${bars}<span class="server-ping">${pingStr}</span></span>
    </div>`;
  });
  el.innerHTML=html;
}

const INCIDENT_LABEL={
  check_fail:'Сбой проверки',
  auto_switch:'Авто-переключение',
  switch_failed:'Не удалось переключиться',
  slow_degraded:'Низкая скорость — переключение',
  slow_redial:'Низкая скорость — переподключение',
  slow_noalt:'Низкая скорость везде',
  wan_down:'Провайдер недоступен',
  wan_recovered:'Интернет восстановлен',
  emergency_muted:'Аварийно на исключённый',
  update:'Обновление',
  update_rollback:'Обновление откачено',
  slow_noswitch:'Низкая скорость — смена сервера выключена',
  dns_failover:'DNS провайдера сменён',
  net_check_switch:'Белые списки — переключение',
  net_check_noalt:'Белые списки — рабочего сервера нет',
  net_check_restore:'Белые списки закончились — возврат'
};
function fmtIncidentTime(ts){
  const d=new Date(ts*1000);
  const now=Date.now()/1000;
  const ago=now-ts;
  if(ago<60)return 'только что';
  if(ago<3600)return Math.floor(ago/60)+' мин назад';
  if(ago<86400)return Math.floor(ago/3600)+' ч назад';
  if(ago<7*86400)return Math.floor(ago/86400)+' дн назад';
  return d.toLocaleDateString('ru-RU')+' '+d.toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'});
}
function renderIncidentsInLog(items){
  const el=document.getElementById('logList');
  if(!el)return;
  if(!items||!items.length){
    el.innerHTML='<div class="log-empty"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M9 12l2 2 4-4"/><circle cx="12" cy="12" r="9"/></svg>Событий нет — всё работает стабильно</div>';
    return;
  }
  el.innerHTML=items.map(it=>{
    const label=INCIDENT_LABEL[it.type]||it.type;
    return `<div class="incident t-${esc(it.type)}${INCIDENT_OK.has(it.type)?' ok':''}">
      <div class="incident-row">
        <span class="incident-type">${esc(label)}</span>
        <span class="incident-time" title="${esc(new Date(it.ts*1000).toLocaleString('ru-RU'))}">${esc(fmtIncidentTime(it.ts))}</span>
      </div>
      ${it.server?`<div class="incident-server">${serverNameDisplay(it.server)}</div>`:''}
      ${it.detail?`<div class="incident-detail">${esc(it.detail)}</div>`:''}
    </div>`;
  }).join('');
}
// The journal holds good news too (an update, a recovered uplink): those are
// shown in green and must not light the red failure badge.
const INCIDENT_OK=new Set(['update','wan_recovered','net_check_restore']);
function updateIncidentsBadge(items){
  const n=items.filter(it=>!INCIDENT_OK.has(it.type)).length;
  const badge=document.getElementById('incidentsBadge');
  if(!badge)return;
  badge.textContent=n;
  badge.style.display=n>0?'inline-flex':'none';
}
async function loadIncidents(){
  try{
    const r=await apiFetch(API+'?action=get-incidents');
    const d=await r.json();
    incidentStats={};
    (d.stats||[]).forEach(s=>{ if(s.host) incidentStats[s.host]=s; });
    updateIncidentsBadge(d.incidents||[]);
    if(state&&state.servers)renderServers(state.servers,state.selected);
    // If user is currently viewing incidents in the log tab, refresh the rendered list too.
    if(currentLogFilter==='incidents')renderIncidentsInLog(d.incidents||[]);
  }catch(e){}
}
// Persist across page reloads — otherwise an overnight watchdog switch is
// missed: page opens, _lastSwitchSeen=null, code records `t` and skips the
// toast, so the user sees a different server with no explanation.
let _lastSwitchSeen=parseInt(localStorage.getItem('eclipvpn.lastSwitchSeen'))||0;
let _lastUpdateSeen=parseInt(localStorage.getItem('eclipvpn.lastUpdateSeen'))||0;
async function fetchStatus(){
  try{
    const r=await apiFetch(API+'?action=status');
    const fresh=await r.json();
    // While a server switch is in flight, the optimistic state.selected is
    // ahead of the backend (we already pointed UI at the new server). Don't
    // let polling clobber that — the user-visible selection should stay
    // sticky until the switch resolves.
    if(_switchPending&&typeof state.selected==='number'){
      fresh.selected=state.selected;
    }
    // pings{} is keyed by array index. When the server list changes (a
    // subscription update / reorder), a stale pings[i] would render against a
    // different server — clear it so stale numbers don't mislead.
    const _oldHosts=(state.servers||[]).map(s=>s&&s.host).join(',');
    const _newHosts=(fresh.servers||[]).map(s=>s&&s.host).join(',');
    if(_oldHosts!==_newHosts)pings={};
    state=fresh;
    _uptimeBase = state.running ? {sec:(+state.uptime||0), at:Date.now()} : null;
    // Detect watchdog failover: if last_switch.time is newer than what we've
    // seen, show a toast. Persisted via localStorage so an overnight switch
    // is announced when the user opens the UI in the morning.
    if(state.last_switch&&state.last_switch.time){
      const t=state.last_switch.time;
      if(t>_lastSwitchSeen){
        _lastSwitchSeen=t;
        localStorage.setItem('eclipvpn.lastSwitchSeen',t);
        const from=state.last_switch.from||'—',to=state.last_switch.to||'—';
        // Sticky toast (duration:0) — easy to miss otherwise; user dismisses.
        toast({title:'Сервер был переключён '+fmtAgo(t),desc:from+' → '+to+' (автоматически, из-за обрыва)'},{type:'info',duration:0});
        loadIncidents();
      }
    }
    // Same pattern for subscription auto-update (cron). Only toast when the
    // server count actually changed — re-fetch with the same list is silent.
    if(state.last_update&&state.last_update.time){
      const t=state.last_update.time;
      if(t>_lastUpdateSeen){
        _lastUpdateSeen=t;
        localStorage.setItem('eclipvpn.lastUpdateSeen',t);
        const cur=state.last_update.count||0,prev=state.last_update.prev_count||0;
        if(cur!==prev){
          const arrow=prev>0?(prev+' → '+cur):(cur+' серверов');
          toast.info('Подписка обновлена',arrow);
        }
      }
    }
    const on=state.running;
    // Don't fight an in-flight start/stop: a poll landing mid-operation
    // still sees the old `running` and would visually bounce the toggle the
    // user just flipped (same guard as _autoModePending / _switchPending).
    if(!_vpnPending)document.getElementById('vpnToggle').checked=on;
    renderSubscriptions();
    // Sync persistent auto_mode toggle from backend state, but stay out of
    // the way while a toggle/auto-select op is in flight — otherwise this
    // 5s poll can flip the visual back to OFF before the operation has
    // finished saving and the user sees the toggle bounce.
    const am=document.getElementById('autoModeToggle');
    if(am&&!_autoModePending&&am.checked!==!!state.auto_mode)am.checked=!!state.auto_mode;
    // auto_start toggle. Default true (matches init.d's `// true` jq fallback).
    const ast=document.getElementById('autoStartToggle');
    const astOn = state.auto_start !== false;
    if(ast && ast.checked !== astOn) ast.checked = astOn;
    const astS = document.getElementById('autoStartStatus');
    if(astS) astS.textContent = astOn ? 'Включено' : 'Выключено';
    // auto_failover badge. Default TRUE, so only an explicit false lights it —
    // an older backend that doesn't send the field must not show the warning.
    const fb=document.getElementById('failoverBadge');
    if(fb) fb.style.display = (state.auto_failover === false) ? 'inline-flex' : 'none';
    renderAutomation();
    const hint=document.getElementById('autoModeHint');
    if(hint){
      if(state.auto_mode){
        hint.textContent='Авто-режим — сервер выбирается автоматически по пингу. Клик по серверу выключает авто.';
        hint.style.color='var(--accent-text)';
      }else{
        hint.textContent='Ручной режим — кликните на сервер, чтобы переключиться. Включите Авто, чтобы система выбирала за вас.';
        hint.style.color='var(--text-muted)';
      }
    }
    const orb=document.getElementById('statusOrb');
    orb.classList.toggle('off',!on);

    if(on){
      document.getElementById('statusTitle').textContent='Подключено';
      const modeText=modeLabel();
      document.getElementById('statusMeta').innerHTML=
        `<span><b>${serverNameDisplay(state.server||'—')}</b></span>`+
        `<span>IP <b>${esc(state.vpn_ip||'—')}</b></span>`+
        `<span id="uptimeLive" class="num" title="С момента последнего запуска или переключения сервера">${fmtUpLive(state.uptime)}</span>`+
        `<span>${modeText}</span>`;
      const hi=document.getElementById('headerInfo');
      hi.className='header-info on';
      hi.innerHTML='<span style="width:6px;height:6px;border-radius:50%;background:var(--green)"></span> '
        +serverNameDisplay(state.server||'')+'<span class="hi-sep" style="color:var(--text-dim);margin:0 2px">·</span><b>'+esc(state.vpn_ip||'—')+'</b>';
      if(!_vpnPending)document.getElementById('vpnMiniToggle').checked=true;
    }else{
      document.getElementById('statusTitle').textContent='Отключено';
      document.getElementById('statusMeta').innerHTML='<span>Нажмите переключатель, чтобы подключиться</span>';
      const hi=document.getElementById('headerInfo');
      hi.className='header-info off';
      hi.innerHTML='<span style="width:6px;height:6px;border-radius:50%;background:var(--red)"></span> Выключено';
      if(!_vpnPending)document.getElementById('vpnMiniToggle').checked=false;
    }

    // #subUrl stays empty — it's an "add subscription" field. The active
    // subscription is shown in the meta card below (with its own «Обновить»).
    document.getElementById('mode-all').classList.toggle('active',state.mode==='all_vpn');
    document.getElementById('mode-block').classList.toggle('active',state.mode==='blocklist');
    renderServers(state.servers,state.selected);
    if(!window._onboardChecked){window._onboardChecked=true;maybeShowOnboard()}
  }catch(e){}
}

// Single timer for ad-hoc status refreshes after user actions.
// Coalesces rapid action sequences (toggle/select/setMode) into one fetch.
let _statusTimer=null;
function scheduleStatus(ms){
  if(_statusTimer)clearTimeout(_statusTimer);
  _statusTimer=setTimeout(()=>{_statusTimer=null;fetchStatus()},ms);
}

// fetch wrapper that surfaces HTTP errors. Without this, a 500 from CGI
// returns an HTML body which then fails JSON.parse and the catch block
// swallows it as a generic 'Ошибка', hiding the real failure.
async function apiFetch(url,opts){
  // Force no-cache on every API call. Browsers were occasionally serving
  // cached GET responses for endpoints whose state changes server-side
  // (auto-update, schedule, status, get-domains), making toggles "stick"
  // in their previous visual position after a successful action.
  // Anti-CSRF is enforced server-side off the Referer/Origin header (uhttpd
  // drops custom headers, so a marker header wouldn't survive). The browser
  // sends a same-host Referer automatically on these same-origin calls, which
  // the CGI checks against its Host for state-changing actions.
  const merged=Object.assign({cache:'no-store',headers:{'Cache-Control':'no-cache','Pragma':'no-cache'}},opts||{});
  if(opts&&opts.headers) merged.headers=Object.assign({},merged.headers,opts.headers);
  // Abort hung requests so a wedged router doesn't leave loading toasts
  // and pending UI locks (e.g. _vpnPending) stuck forever — fetch otherwise
  // waits indefinitely and the catch/finally never runs. Default 20s;
  // long-running actions (update, auto-select, probe/set-server, restart)
  // pass opts.timeoutMs — at 20s they aborted client-side while the router
  // kept going, and e.g. selectServer then "rolled back" a switch that had
  // actually succeeded.
  const _ac=new AbortController();
  const _to=setTimeout(()=>_ac.abort(),(opts&&opts.timeoutMs)||20000);
  if(!merged.signal)merged.signal=_ac.signal;
  try{
    const r=await fetch(url,merged);
    if(!r.ok)throw new Error('HTTP '+r.status);
    return r;
  }finally{
    clearTimeout(_to);
  }
}

// Backend errors are English; translate the lifecycle ones, pass the rest through.
const ERR_RU={
  'already running':'VPN уже запущен',
  'another lifecycle op in progress':'Уже выполняется другая операция — подождите немного',
  'no subscription configured — add one in Settings':'Нет подписки — добавьте её в Настройках',
  'subscription failed':'Не удалось загрузить подписку',
  'proxy engine failed to start':'Не запустился прокси-движок',
  'VPN connection failed':'Сервер не отвечает — попробуйте другой',
  'sing-box failed':'Не запустился sing-box',
  'VPN start failed':'Не удалось запустить VPN'
};
function ruErr(e){return ERR_RU[e]||String(e||'')}

// Promise-based confirm/prompt on a native <dialog> (focus trap and Esc for free).
// Resolves true / the typed string, or null when dismissed.
function askBox(o){
  const d=document.getElementById('dlg'),inp=document.getElementById('dlgInput'),ok=document.getElementById('dlgOk');
  if(d.open)return Promise.resolve(null);
  const text=document.getElementById('dlgText'),cancel=document.getElementById('dlgCancel');
  document.getElementById('dlgTitle').textContent=o.title;
  text.textContent=o.text||'';text.hidden=!o.text;
  ok.textContent=o.ok||'Да';
  ok.className='btn '+(o.danger?'btn-danger':'btn-primary');
  const isPrompt=o.value!==undefined;
  inp.hidden=!isPrompt;inp.value=isPrompt?o.value:'';
  return new Promise(res=>{
    let result=null;
    document.getElementById('dlgForm').onsubmit=()=>{result=isPrompt?inp.value:true};
    cancel.onclick=()=>d.close();
    d.onclick=e=>{if(e.target===d){const r=d.getBoundingClientRect();
      if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)d.close()}};
    d.onclose=()=>res(result);
    d.showModal();
    if(isPrompt){inp.focus();inp.select()}else cancel.focus();
  });
}

let _vpnPending=false;
async function toggleVPN(){
  const cb=document.getElementById('vpnToggle');
  if(_vpnPending){cb.checked=!cb.checked;return}
  const on=cb.checked;
  // Pending from here on, so a status poll can't flip the switch under the dialog.
  _vpnPending=true;cb.disabled=true;
  if(!on&&!await askBox({title:'Отключить VPN?',text:'Весь трафик пойдёт напрямую, заблокированные сайты не откроются.',ok:'Отключить',danger:true})){
    _vpnPending=false;cb.disabled=false;
    cb.checked=true;document.getElementById('vpnMiniToggle').checked=true;return;
  }
  const tid=toast.loading(on?'Подключаемся…':'Отключаем…');
  try{
    const r=await apiFetch(API+'?action='+(on?'start':'stop'),{timeoutMs:65000});const d=await r.json();
    if(d.error)updateToast(tid,on?'Не удалось подключиться':'Не удалось отключить',{type:'error',desc:ruErr(d.error),duration:8000});
    else updateToast(tid,on?'VPN подключён':'VPN отключён',{type:'success'});
  }catch(e){updateToast(tid,'Ошибка связи',{type:'error'})}
  finally{_vpnPending=false;cb.disabled=false}
  scheduleStatus(2000);
}

// Mute / un-mute a server: it stops being a candidate for auto-select,
// auto-eval and watchdog failover, but stays selectable by hand and keeps
// running if it's the one currently connected. Used for the billed CDN
// ("Обход") relays, which must never switch themselves on unattended.
//
// stopPropagation is load-bearing: the button lives INSIDE the row whose
// onclick is selectServer, so without it a mute click also switches server.
let _mutePending=false;
async function toggleMute(ev,i,isMuted){
  ev.stopPropagation();
  if(_mutePending)return;
  if(!state.servers||!state.servers[i])return;
  _mutePending=true;
  const name=state.servers[i].name||'сервер';
  try{
    const r=await apiFetch(API+'?action='+(isMuted?'unmute-server':'mute-server')+'&index='+i,{timeoutMs:15000});
    const d=await r.json();
    if(d.error){toast.error(d.error);return;}
    // Optimistic local flip so the icon reacts instantly; the next /status
    // poll re-derives `muted` from the backend and wins if they disagree.
    state.servers[i].muted=!isMuted;
    renderServers(state.servers,state.selected);
    if(d.status==='unmuted'){
      // Un-muting through a FAMILY token ("Обход") frees the siblings too —
      // say so, otherwise the extra servers silently rejoin auto-switching.
      const freed=(d.muted_count!=null&&Array.isArray(d.removed_tokens)&&d.removed_tokens.length)
        ? d.removed_tokens.join(', ') : '';
      toast.success('Снова в автовыборе: '+name+(freed?' (снят тег «'+freed+'» — вместе с похожими серверами)':''));
    }else if(d.status==='muted'){
      toast.success(name+' исключён из автовыбора'
        +(d.muted_count>1?' (всего исключено: '+d.muted_count+')':''));
    }
  }catch(e){toast.error('Не удалось сохранить');}
  finally{_mutePending=false;scheduleStatus(1500);}
}

// Server switch is a 2-phase flow with optimistic UI:
// 1. Pre-flight probe (3-5s) — verify the target works without touching prod
// 2. Soft restart (5-7s) — actually switch
// On any failure we roll back the visual selection so the UI stays honest.
let _switchPending=false;
async function selectServer(i){
  if(_switchPending)return;
  if(i===state.selected)return;  // already selected — ignore noise click
  if(!state.servers||!state.servers[i])return;

  // Manual click while auto-mode is on counts as user opting into manual.
  // Save prior state so we can restore if the switch fails — otherwise a
  // failed click silently kills auto-mode without the user knowing.
  const wasAuto=state.auto_mode;
  if(wasAuto){
    // Hold _autoModePending across the whole switch so a status poll landing
    // mid-operation doesn't re-read the not-yet-committed backend auto_mode=true
    // and visually flip the toggle back on for a cycle. Cleared in finally.
    _autoModePending=true;
    state.auto_mode=false;
    const am=document.getElementById('autoModeToggle');
    if(am)am.checked=false;
    apiFetch(API+'?action=set-config&key=auto_mode&value=false').catch(()=>{});
  }

  _switchPending=true;
  const oldSelected=state.selected;
  const name=state.servers[i].name||'сервер';
  // Optimistic UI: highlight new server immediately, lock the rest of the list,
  // mark the target with .switching for the spinner+pulse.
  state.selected=i;
  renderServers(state.servers,i,i);
  const list=document.getElementById('serverList');
  list.classList.add('locked');

  // Single toast id reused across phases. updateToast dismisses+recreates,
  // so we must capture its returned id each time — otherwise the second
  // call dismisses an already-gone toast and the loading toast on screen
  // becomes orphaned (visible forever).
  let tid=toast.loading('Тестируем '+name+'…');

  try{
    // Phase 1: probe — temporary xray, no production impact if it fails
    const pr=await apiFetch(API+'?action=probe-server&index='+i,{timeoutMs:90000});
    const pd=await pr.json();
    if(pd.error)throw new Error(pd.error);

    tid=updateToast(tid,'Сервер работает ('+pd.ip+') — переключаемся…',{type:'loading',duration:0});

    // Phase 2: actual switch — soft restart with new selected_server
    const sr=await apiFetch(API+'?action=set-server&index='+i,{timeoutMs:90000});
    const sd=await sr.json();
    if(sd.error)throw new Error(sd.error);

    // Refresh state BEFORE showing success — otherwise header lags 2s
    // behind because polling kicks in only via scheduleStatus(2000).
    // The set-server response already contains the new server+vpn_ip,
    // but other UI bits (uptime, traffic stats card, mini-toggle) read
    // from `state`, so a fresh fetchStatus updates them all coherently.
    try{await fetchStatus()}catch(_){}

    tid=updateToast(tid,name,{type:'success',desc:'IP: '+(sd.vpn_ip||pd.ip),duration:2500});
  }catch(e){
    // Roll back: target couldn't be activated, return UI to previous state.
    // Production VPN was untouched (probe runs in isolation).
    state.selected=oldSelected;
    renderServers(state.servers,oldSelected);
    // Also restore auto-mode if we silently turned it off — user didn't
    // actually succeed in their manual override, no reason to lose auto.
    if(wasAuto){
      state.auto_mode=true;
      const am=document.getElementById('autoModeToggle');
      if(am)am.checked=true;
      apiFetch(API+'?action=set-config&key=auto_mode&value=true').catch(()=>{});
    }
    const reason=(e&&e.message)||'неизвестная ошибка';
    let humanReason=reason;
    if(/unreachable/i.test(reason))humanReason='Сервер не отвечает';
    else if(/HTTP 5/.test(reason))humanReason='Ошибка роутера';
    tid=updateToast(tid,'Не удалось переключить',{type:'error',desc:humanReason,duration:4500});
    // Backend logged a switch_failed incident — refresh panel so the user
    // sees a fresh entry (and the badge on the failing server) immediately.
    loadIncidents();
  }finally{
    _switchPending=false;
    _autoModePending=false;   // release the auto-mode sync lock taken above
    // Render first, then unlock — avoids a microsecond gap where stale DOM
    // is interactive after the lock is removed.
    renderServers(state.servers,state.selected);
    list.classList.remove('locked');
    scheduleStatus(2000);
  }
}
// Shared lock for the two server-wide probe sweeps (doPing + doAutoSelect).
// Both hammer the router (many xrays/sing-boxes + curl bursts); a single flag
// gating BOTH, and disabling BOTH the ping button and the Auto toggle, stops a
// second sweep from being launched on top of the first.
let _probePending=false;
async function doPing(){
  if(_probePending)return;
  _probePending=true;
  const b=document.getElementById('pingBtn');
  const am=document.getElementById('autoModeToggle');
  if(b){b.disabled=true;b.innerHTML='<span class="spinner"></span> Проверяем';}
  if(am)am.disabled=true;
  try{const r=await apiFetch(API+'?action=ping',{timeoutMs:90000});const d=await r.json();if(Array.isArray(d))storePings(d);renderServers(state.servers,state.selected)}catch(e){}
  _probePending=false;
  if(b){b.disabled=false;b.textContent='Проверить пинг';}
  if(am)am.disabled=false;
}
// Maps backend status code to a short Russian phrase for the toast log.
const _AUTO_STATUS_RU={
  skipped_metered:'платный трафик',
  skipped_muted:'исключён из автовыбора',
  skipped_exit_country:'выход в запрещённой стране',
  unreachable:'нет связи',
  probe_failed:'VLESS не прошёл',
  already_active:'уже активен ✓',
  selected:'выбран ✓'
};
function _formatAttempts(attempts){
  if(!attempts||!attempts.length)return '';
  return attempts.map(a=>{
    const rtt=(a.rtt_ms!=null)?(' · '+a.rtt_ms+' мс'):'';
    return (a.name||'?')+rtt+' — '+(_AUTO_STATUS_RU[a.status]||a.status);
  }).join('\n');
}
// Toggle persistent auto-mode preference. ON also kicks off an immediate
// auto-select; OFF just clears the flag (current selection stays).
// _autoModePending blocks fetchStatus's toggle-sync from clobbering our
// in-flight value (poll runs every 5s, this op can take 15s+).
let _autoModePending=false;
async function toggleAutoStart(enabled){
  // Persists `auto_start` in /etc/eclipvpn/config.json. Read by /etc/init.d/
  // eclipvpn at boot — if false, the service does not auto-start. Doesn't
  // affect the currently-running VPN, only the next reboot.
  const t=document.getElementById('autoStartToggle');
  const s=document.getElementById('autoStartStatus');
  if(t)t.disabled=true;
  try{
    await apiFetch(API+'?action=set-config&key=auto_start&value='+(enabled?'true':'false'));
    state.auto_start=enabled;
    if(s)s.textContent=enabled?'Включено':'Выключено';
    toast.success(enabled?'Автозапуск включён':'Автозапуск выключен',
                  enabled?'VPN будет запускаться после загрузки роутера':'После перезагрузки роутера VPN не запустится сам');
  }catch(e){
    if(t)t.checked=!enabled;
    toast.error('Ошибка','Не удалось сохранить настройку');
  }finally{
    if(t)t.disabled=false;
  }
}

function toggleAutoHint(){
  const p=document.getElementById('autoModeHint');
  p.hidden=!p.hidden;
  document.getElementById('autoHintBtn').setAttribute('aria-expanded',String(!p.hidden));
}
function modeLabel(){
  return state.mode!=='all_vpn'?'Только по списку':(state.full_tunnel?'Весь трафик, включая РФ':'Весь трафик кроме РФ');
}
// --- Settings ▸ Автоматика -------------------------------------------------
// _behaviourPending keeps the 5s status poll from flipping a toggle back while
// its save is still in flight.
let _behaviourPending=false;
function _ruExitBlocked(){return String(state.blocked_exit_countries||'').split(',').includes('RU')}
function renderAutomation(){
  if(_behaviourPending)return;
  const set=(id,v)=>{const e=document.getElementById(id);if(e)e.checked=v};
  const af=state.auto_failover!==false;
  set('afToggle',af);
  set('tgToggle',state.tput_guard!==false);
  set('ncToggle',state.net_check_switch!==false);
  set('ruExitToggle',_ruExitBlocked());
  set('ftToggle',!!state.full_tunnel);
  // auto_failover gates every automatic switch, so these two have no effect
  // without it (the RU filter still applies to a manual auto-select).
  document.getElementById('ncToggleRow').classList.toggle('off',!af);
  document.getElementById('ftToggleRow').style.display=state.mode==='all_vpn'?'':'none';
  document.getElementById('automationNote').textContent=af
    ?'«Авто» у списка серверов — отдельная функция: периодически ищет самый быстрый сервер, даже если обрыва не было.'
    :'Смена сервера выключена: «Белые списки» и периодический подбор «Авто» не действуют, контроль скорости только переподключает.';
}
async function _saveBehaviour(key,value){
  const r=await apiFetch(API+'?action=set-config&key='+key+'&value='+encodeURIComponent(value));
  const d=await r.json();
  if(d.error)throw new Error(d.error);
}
async function _behaviour(cb,fn){
  if(_behaviourPending){cb.checked=!cb.checked;return}
  _behaviourPending=true;cb.disabled=true;
  try{await fn()}
  catch(e){toast.error('Не удалось сохранить',ruErr(e.message))}
  finally{_behaviourPending=false;cb.disabled=false;renderAutomation()}
}
function setBehaviour(key,cb){
  const on=cb.checked;
  return _behaviour(cb,async()=>{
    await _saveBehaviour(key,on?'true':'false');
    state[key]=on;
    document.getElementById('failoverBadge').style.display=state.auto_failover===false?'inline-flex':'none';
    toast.success(on?'Включено':'Выключено',document.querySelector('#'+cb.id+'Row .setting-row-title').textContent);
  });
}
function setRuExitBlock(cb){
  const on=cb.checked;
  return _behaviour(cb,async()=>{
    // Other countries set via CLI stay; "off" is the backend's spelling of empty.
    const list=String(state.blocked_exit_countries||'').split(',').filter(c=>c&&c!=='RU');
    if(on)list.unshift('RU');
    await _saveBehaviour('blocked_exit_countries',list.join(',')||'off');
    state.blocked_exit_countries=list.join(',');
    toast.success(on?'Включено':'Выключено','Не выбирать выход в России');
  });
}
function setFullTunnel(cb){
  const on=cb.checked;
  return _behaviour(cb,async()=>{
    if(!await askBox({title:on?'Пустить российские сайты через VPN?':'Вернуть российские сайты напрямую?',
      text:state.running?'VPN перезапустится — связь ненадолго прервётся.':'',ok:'Применить'}))return;
    await _saveBehaviour('full_tunnel',on?'true':'false');
    state.full_tunnel=on;
    if(!state.running){toast.info('Сохранено','Применится при включении VPN');return}
    const tid=toast.loading('Применяем…');
    let err='';
    try{const d=await(await apiFetch(API+'?action=restart',{timeoutMs:65000})).json();err=d.error||''}
    catch(e){err='нет ответа роутера'}
    if(err)updateToast(tid,'Сохранено, но не применено',{type:'warning',desc:ruErr(err)+'. Нажмите «Перезапустить» в Настройках.',duration:9000});
    else updateToast(tid,modeLabel(),{type:'success'});
    scheduleStatus(2000);
  });
}
async function toggleAutoMode(enabled){
  _autoModePending=true;
  const t=document.getElementById('autoModeToggle');
  if(t)t.disabled=true;
  try{
    await apiFetch(API+'?action=set-config&key=auto_mode&value='+(enabled?'true':'false'));
    state.auto_mode=enabled;
    if(enabled){
      // Wait for the immediate auto-select to finish before unlocking the
      // toggle, so a quick second flick doesn't fire a parallel run.
      await doAutoSelect();
    }else{
      toast.info('Ручной режим',state.auto_failover===false?'Сервер меняете только вы':'Сервер сменится только при сбое');
    }
  }catch(e){
    if(t)t.checked=!enabled;
    toast.error('Ошибка','Не удалось сохранить режим');
  }finally{
    _autoModePending=false;
    if(t)t.disabled=false;
  }
}
async function doAutoSelect(){
  // Shares the _probePending lock with doPing — running both in parallel hammers
  // the router. The Auto toggle is also disabled by its caller (toggleAutoMode)
  // and by doPing, so the two sweeps can't overlap.
  if(_probePending)return;
  _probePending=true;
  const pingBtn=document.getElementById('pingBtn');
  if(pingBtn)pingBtn.disabled=true;
  let tid=toast.loading('Измеряем все серверы и выбираем лучший…');
  try{
    const r=await apiFetch(API+'?action=auto-select',{timeoutMs:120000});const d=await r.json();
    if(d.error){
      // Re-throw with attempts so catch can still show them
      const err=new Error(d.error);err.attempts=d.attempts;throw err;
    }
    const log=_formatAttempts(d.attempts);
    let summary=d.switched?(d.server+' · '+d.rtt_ms+' мс'):('Уже на лучшем: '+d.server);
    // d.emergency = every un-muted server was unreachable, so the picker fell
    // back to a muted (billed) one. Never let that pass as a normal success —
    // the whole point of the mute list is that it costs money.
    if(d.emergency)summary='⚠ Свободных серверов нет — выбран исключённый из автовыбора (может быть платным).\n'+summary;
    const desc=log?(summary+'\n\n'+log):summary;
    tid=updateToast(tid,d.switched?(d.emergency?'Переключено аварийно':'Переключено'):'Без изменений',
      {type:d.emergency?'warning':'success',desc,duration:d.emergency?10000:7000});
    try{await fetchStatus()}catch(_){}
  }catch(e){
    const log=e.attempts?_formatAttempts(e.attempts):'';
    const reason=(e&&e.message)||'Все серверы недоступны';
    const desc=log?(reason+'\n\n'+log):reason;
    tid=updateToast(tid,'Не удалось подобрать',{type:'error',desc,duration:7000});
  }finally{
    _probePending=false;
    if(pingBtn)pingBtn.disabled=false;
  }
}
async function setMode(m){
  if(state.mode===m){return}
  const name=m==='all_vpn'?'«Всё через VPN»':'«По списку»';
  // Visual feedback on the clicked card immediately — user sees a pulse
  // before the toast and before the backend round-trip completes.
  const card=document.getElementById(m==='all_vpn'?'mode-all':'mode-block');
  if(card){card.classList.add('applying');setTimeout(()=>card.classList.remove('applying'),900)}
  const tid=toast.loading('Применяем режим…');
  try{
    const r=await apiFetch(API+'?action=set-mode&mode='+m,{timeoutMs:90000});const d=await r.json();
    if(d.error)updateToast(tid,'Ошибка',{type:'error',desc:d.error});
    else updateToast(tid,'Режим: '+name,{type:'success'});
  }catch(e){updateToast(tid,'Ошибка связи',{type:'error'})}
  scheduleStatus(3000);
}
let _subActionPending=false;
async function addSubscription(){
  const inp=document.getElementById('subUrl');
  const nameInp=document.getElementById('subName');
  const u=inp.value.trim();
  const nm=nameInp?nameInp.value.trim():'';
  if(!u){_showInputError(inp,'Вставьте ссылку на подписку или сервер');inp.focus();return}
  if(!/^(https?|vless|vmess|trojan|ss|hysteria2|hy2):\/\//i.test(u)){_showInputError(inp,'Нужна http(s)-ссылка на подписку или vless:// / vmess:// / trojan:// / ss:// / hysteria2:// сервер');inp.focus();return}
  if(_subActionPending)return;   // a subscription op is already in flight — ignore double-click
  _subActionPending=true;
  const tid=toast.loading('Добавляем подписку, загружаем серверы…');
  try{
    // op=add via POST so the URL+name (free text / credential token) never hit
    // the query string or a process listing. cmd_sub add re-fetches all subs.
    const r=await apiFetch(API+'?action=sub&op=add',{method:'POST',body:JSON.stringify({url:u,name:nm}),timeoutMs:90000});
    const d=await r.json();
    if(d.error){updateToast(tid,'Не удалось добавить подписку',{type:'error',desc:d.error});}
    else{
      updateToast(tid,'Подписка добавлена',{type:'success'});
      inp.value='';if(nameInp)nameInp.value='';
      // Servers should refresh themselves — enable auto-update by default.
      apiFetch(API+'?action=auto-update&mode=enable').catch(()=>{});
    }
  }catch(e){updateToast(tid,'Ошибка связи',{type:'error'})}
  _subActionPending=false;
  scheduleStatus(800);
}
async function subToggle(id,on){
  if(_subActionPending)return;
  _subActionPending=true;
  const tid=toast.loading(on?'Включаем подписку…':'Выключаем подписку…');
  try{
    const r=await apiFetch(API+'?action=sub&op='+(on?'enable':'disable')+'&id='+encodeURIComponent(id),{timeoutMs:90000});
    const d=await r.json();
    if(d.error)updateToast(tid,'Ошибка',{type:'error',desc:d.error});
    else updateToast(tid,on?'Подписка включена':'Подписка выключена',{type:'success'});
  }catch(e){updateToast(tid,'Ошибка связи',{type:'error'})}
  _subActionPending=false;scheduleStatus(800);
}
function _subName(id){const s=((state&&state.subscriptions)||[]).find(x=>x.id===id);return s?(s.name||''):''}
async function subRemove(id){
  if(_subActionPending)return;
  if(!await askBox({title:'Удалить подписку «'+(_subName(id)||'')+'»?',text:'Её серверы исчезнут из списка.',ok:'Удалить',danger:true}))return;
  _subActionPending=true;
  const tid=toast.loading('Удаляем подписку…');
  try{
    const r=await apiFetch(API+'?action=sub&op=remove&id='+encodeURIComponent(id),{timeoutMs:90000});
    const d=await r.json();
    if(d.error)updateToast(tid,'Ошибка',{type:'error',desc:d.error});
    else updateToast(tid,'Подписка удалена',{type:'success'});
  }catch(e){updateToast(tid,'Ошибка связи',{type:'error'})}
  _subActionPending=false;scheduleStatus(800);
}
async function subRename(id){
  if(_subActionPending)return;
  const name=await askBox({title:'Название подписки',value:_subName(id)||'',ok:'Сохранить'});
  if(name===null)return;
  const nm=name.trim();if(!nm)return;
  _subActionPending=true;
  const tid=toast.loading('Переименовываем…');
  try{
    const r=await apiFetch(API+'?action=sub&op=rename&id='+encodeURIComponent(id),{method:'POST',body:JSON.stringify({name:nm}),timeoutMs:90000});
    const d=await r.json();
    if(d.error)updateToast(tid,'Ошибка',{type:'error',desc:d.error});
    else updateToast(tid,'Переименовано',{type:'success'});
  }catch(e){updateToast(tid,'Ошибка связи',{type:'error'})}
  _subActionPending=false;scheduleStatus(800);
}
let _updatePending=false;
async function doUpdate(){
  // Manual refresh of the server list — re-fetches EVERY enabled subscription
  // (not the add-field). Works any time at least one subscription exists.
  if(!state||!(state.subscriptions&&state.subscriptions.length)){toast.error('Сначала добавьте подписку');return}
  if(_updatePending)return;
  _updatePending=true;
  const b=document.getElementById('updateBtn');if(b){b.disabled=true;b.textContent='Обновляем…';}
  const tid=toast.loading('Обновляем список серверов…');
  try{
    const r=await apiFetch(API+'?action=update',{timeoutMs:90000});const d=await r.json();
    if(d.error)updateToast(tid,'Ошибка обновления',{type:'error',desc:d.error});
    else updateToast(tid,'Список обновлён',{type:'success',desc:'Найдено серверов: '+d.servers});
  }catch(e){updateToast(tid,'Ошибка',{type:'error'})}
  _updatePending=false;
  // Re-query instead of reusing `b` — the status poll may have rebuilt the
  // card while we were away, leaving `b` detached.
  const b2=document.getElementById('updateBtn');
  if(b2){b2.disabled=false;b2.textContent='Обновить';}
  scheduleStatus(2000);
}
async function doRestart(){
  const tid=toast.loading('Перезапускаем EclipVPN…');
  try{
    // force=1 bypasses the unchanged-config fast path in cmd_restart, so
    // a manual click always physically restarts xray + sing-box.
    const r=await apiFetch(API+'?action=restart&force=1',{timeoutMs:65000});
    const d=await r.json();
    if(d.error)updateToast(tid,'Ошибка',{type:'error',desc:d.error});
    else if(d.status==='unchanged')updateToast(tid,'VPN уже работает',{type:'info'});
    else updateToast(tid,'EclipVPN перезапущен',{type:'success'});
  }catch(e){updateToast(tid,'Ошибка связи',{type:'error'})}
  scheduleStatus(3000);
}
// Collapse/expand a card. Persisted in localStorage so the user's preference
// survives reloads — they expanded it once, no need to expand again every visit.
function toggleCollapsible(id){
  const el=document.getElementById(id);
  if(!el)return;
  const open=!el.classList.contains('expanded');
  el.classList.toggle('expanded',open);
  const head=el.querySelector('.card-head');
  if(head)head.setAttribute('aria-expanded',open?'true':'false');
  try{localStorage.setItem('eclipvpn.collapse.'+id,open?'1':'0')}catch(_){}
}
function restoreCollapsibles(){
  ['directCard','vpnCard','presetsCard'].forEach(id=>{
    const el=document.getElementById(id);
    if(!el)return;
    const saved=localStorage.getItem('eclipvpn.collapse.'+id);
    if(saved==='1')el.classList.add('expanded');
    const head=el.querySelector('.card-head');
    if(head)head.setAttribute('aria-expanded',saved==='1'?'true':'false');
  });
}

const _domData={direct:{custom:[],builtin:[]},vpn:{custom:[],builtin:[]}};
const DOM_NOTE={
  direct:'Кроме этого списка напрямую идут ещё ~5000 российских доменов (geosite-ru).',
  vpn:'Встроенный список: нейросети, YouTube и другие недоступные из РФ сервисы.'
};
function renderDomainList(list){
  const el=document.getElementById(list+'Domains');
  const {custom,builtin}=_domData[list];
  const raw=document.getElementById(list+'Search').value.trim().toLowerCase();
  const q=toPunycode(raw);
  const hit=d=>!raw||d.toLowerCase().includes(raw)||(q&&d.toLowerCase().includes(q));
  const mine=custom.filter(hit),base=builtin.filter(hit);
  const wasOpen=!!el.querySelector('details[open]');
  // data-* attributes + the delegated click: a domain never crosses an
  // HTML-attribute → JS-string boundary.
  const customTag=d=>{const e=esc(d);return `<span class="tag">${e}<span class="tag-remove" role="button" tabindex="0" aria-label="Удалить ${e}" data-domain="${e}" data-list="${list}">×</span></span>`};
  el.classList.add('scrollable');
  el.innerHTML=(raw&&!mine.length&&!base.length)
    ?`<div class="domains-note" style="flex-basis:100%">В списке нет «${esc(raw)}»</div>`
    :`<div class="domains-note" style="flex-basis:100%">Ваши: ${mine.length}</div>`
      +(mine.map(customTag).join('')||(raw?'':'<div class="domains-note" style="flex-basis:100%">Пока ничего не добавлено</div>'))
      +(base.length?`<details class="dom-builtin"${raw||wasOpen?' open':''}><summary>Встроенные: ${base.length}</summary><div class="domains-note">${DOM_NOTE[list]} Удалить их нельзя.</div><div class="dom-tags">${base.map(d=>`<span class="tag tag-readonly">${esc(d)}</span>`).join('')}</div></details>`:'');
}
async function loadDomains(){
  try{const r=await apiFetch(API+'?action=get-domains');const d=await r.json();
    const dirBuiltin=d.ru_domains_builtin||[], dirCustom=d.custom_direct||[];
    const vpnBuiltin=d.vpn_domains_builtin||[], vpnCustom=d.custom_vpn||[];
    document.getElementById('directCount').textContent=dirBuiltin.length+dirCustom.length;
    document.getElementById('vpnCount').textContent=vpnBuiltin.length+vpnCustom.length;
    // Inline onclick="removeDomain('${...}')" was XSS-unsafe — esc() HTML-
    // escapes but the browser decodes the attribute back before passing to
    // the JS parser, so a single quote in a domain name escaped the string.
    // Now: data-* attributes + delegated click on the container, value
    // never crosses an HTML→JS boundary.
    _domData.direct={custom:dirCustom,builtin:dirBuiltin};
    _domData.vpn={custom:vpnCustom,builtin:vpnBuiltin};
    renderDomainList('direct');renderDomainList('vpn');
  }catch(e){}
}

const PRESET_LABELS = {
  youtube: 'YouTube', spotify: 'Spotify', twitter: 'Twitter / X',
  instagram: 'Instagram', facebook: 'Facebook / Messenger',
  tiktok: 'TikTok', reddit: 'Reddit',
  ru_vpn: '🇷🇺 РФ-сервисы через VPN (ЮKassa и т.п. — недоступны напрямую)'
};
async function loadPresets(){
  try{
    const r=await apiFetch(API+'?action=preset&op=list');
    const d=await r.json();
    const list=document.getElementById('presetsList');
    if(!list||!d.presets){return}
    const enabledCount=d.presets.filter(p=>p.enabled).length;
    document.getElementById('presetsCount').textContent=
      enabledCount?(enabledCount+' / '+d.presets.length):d.presets.length;
    list.innerHTML=d.presets.map(p=>{
      const label=PRESET_LABELS[p.name]||p.name;
      return `<label class="preset-row" style="display:flex;align-items:center;gap:10px;padding:8px 0;cursor:pointer">`+
        `<input type="checkbox" data-preset="${esc(p.name)}" ${p.enabled?'checked':''}>`+
        `<span style="flex:1">${esc(label)}</span>`+
        `<span style="color:var(--text-muted);font-size:12px">${plural(p.domain_count,'домен','домена','доменов')}</span>`+
      `</label>`;
    }).join('');
  }catch(e){}
}
async function togglePreset(name,enabled){
  const op=enabled?'enable':'disable';
  const loadingId=toast.loading('Применяется…');
  try{
    const r=await apiFetch(API+'?action=preset&op='+op+'&name='+encodeURIComponent(name));
    const j=await r.json().catch(()=>({}));
    if(j&&j.error){
      dismissToast(loadingId);
      toast.error('Ошибка',j.error);
      loadPresets();  // revert checkbox state
      return;
    }
    const label=PRESET_LABELS[name]||name;
    updateToast(loadingId,
      {title:enabled?'Включён':'Выключен',desc:label+(enabled?' → через VPN':' → по умолчанию')},
      {type:'success'});
    loadPresets();
    loadDomains();  // vpn_domains.list mutated — refresh tag count
  }catch(e){
    dismissToast(loadingId);
    toast.error('Не удалось применить');
    loadPresets();
  }
}
document.addEventListener('change',e=>{
  const cb=e.target.closest('input[type="checkbox"][data-preset]');
  if(cb)togglePreset(cb.dataset.preset,cb.checked);
});

// Delegated handler for tag-remove buttons (data-domain + data-list). Picks
// up both click and keyboard activation (Enter/Space). Bound once.
document.addEventListener('click', e => {
  const btn = e.target.closest('.tag-remove[data-domain]');
  if (btn) removeDomain(btn.dataset.domain, btn.dataset.list);
});

// Delegated handler for the per-device route switch. data-* keeps the mac/ip
// out of an HTML-attr→JS-string boundary. Real <button>s, so keyboard works.
document.addEventListener('click', e => {
  const b = e.target.closest('.seg-btn[data-dev-id]');
  if (b && !b.classList.contains('on')) setDeviceRoute(b.dataset.devId, b.dataset.devIp, b.dataset.devRoute);
});
// Keyboard activation comes from the global role=button keydown handler
// (it synthesizes a click, which lands in the delegate above). A dedicated
// keydown delegate here fired removeDomain a second time per keypress.
// Convert non-ASCII (Cyrillic etc.) domain to its ASCII Punycode form so
// the CGI's strict ASCII-only validator accepts it. "сайт.рф" → "xn--80aswg.xn--p1ai".
// Returns original on any error so unrelated input is preserved.
function toPunycode(s){
  if(!s||/^[\x00-\x7F]+$/.test(s))return s;  // already pure ASCII
  try{
    // URL API does IDN→Punycode conversion as part of hostname normalization.
    // Strip wildcard prefix if present, convert, then re-attach.
    const wild=s.startsWith('*.')?'*.':'';
    const stripped=wild?s.slice(2):s;
    const u=new URL('http://'+stripped);
    return wild+u.hostname;
  }catch(_){return s}
}
function _showInputError(inp,msg){
  inp.classList.add('error');
  let m=inp.parentElement.parentElement.querySelector('.input-error-msg');
  if(!m){
    m=document.createElement('div');m.className='input-error-msg';
    inp.parentElement.parentElement.insertBefore(m,inp.parentElement.nextSibling);
  }
  m.textContent=msg;m.classList.add('visible');
  const clear=()=>{inp.classList.remove('error');m.classList.remove('visible');inp.removeEventListener('input',clear)};
  inp.addEventListener('input',clear);
}
async function addDomain(list){
  const inp=document.getElementById(list==='direct'?'addDirectInput':'addVpnInput');
  const raw=inp.value.trim();
  if(!raw){_showInputError(inp,'Введите домен или IP, например: example.com или 1.2.3.0/24');return}
  // Domain → punycode + standard hostname check; bare IPv4 (with optional /CIDR)
  // is also accepted in the direct list — apps that hit hardcoded IPs (camera
  // streams, push services) need IP-based rules since SNI sniffing won't fire.
  // "*.example.com" → "example.com": the backend matches by domain_suffix,
  // which already covers subdomains; a literal "*." entry would never match
  // anything in sing-box, and the validator below rightly rejects "*".
  let d=toPunycode(raw);
  if(d.startsWith('*.'))d=d.slice(2);
  const isIp4=/^(\d{1,3}\.){3}\d{1,3}(\/(3[0-2]|[12]?\d))?$/.test(d);
  const isHost=/^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i.test(d);
  if(!isIp4 && !isHost){
    _showInputError(inp,'Похоже на неверный домен/IP. Примеры: «example.com», «1.2.3.4», «1.2.3.0/24» — без https:// и /пути');return;
  }
  if(isIp4 && list==='vpn'){
    _showInputError(inp,'IP-адреса можно добавлять только в список «Напрямую»');return;
  }
  // Backend now soft-restarts sing-box inside add-domain so the new rule
  // is live by the time we get the response (~5-7s). Show a loading toast
  // immediately so the user sees that something's happening, then upgrade
  // it to success/info when the response lands.
  const loadingId=toast.loading('Применяется…');
  try{
    const r=await apiFetch(API+'?action=add-domain&domain='+encodeURIComponent(d)+'&list='+list);
    const j=await r.json().catch(()=>({}));
    if(j&&j.error){dismissToast(loadingId);_showInputError(inp,j.error);return}
    inp.value='';
    const display=raw!==d?(raw+' ('+d+')'):d;
    const desc=display+(list==='direct'?' → напрямую':' → через VPN');
    if(j&&j.applied===false){
      // VPN was off — saved to file but won't take effect until next start
      updateToast(loadingId,{title:'Сохранено',desc:desc+' · применится при включении VPN'},{type:'info'});
    }else{
      updateToast(loadingId,{title:'Домен добавлен',desc:desc},{type:'success'});
    }
    loadDomains();
  }catch(e){dismissToast(loadingId);_showInputError(inp,'Не удалось сохранить — попробуйте снова')}
}
async function removeDomain(d,list){
  const loadingId=toast.loading('Применяется…');
  try{
    const r=await apiFetch(API+'?action=remove-domain&domain='+encodeURIComponent(d)+'&list='+list);
    const j=await r.json().catch(()=>({}));
    if(j&&j.applied===false){
      updateToast(loadingId,{title:'Удалён',desc:d+' · применится при включении VPN'},{type:'info'});
    }else{
      updateToast(loadingId,{title:'Удалён',desc:d},{type:'success'});
    }
    loadDomains();
  }catch(e){dismissToast(loadingId);toast.error('Ошибка')}
}

function detectDeviceType(name){
  const n=(name||'').toLowerCase();
  if(!n||n==='*')return{icon:'#i-device',label:''};
  if(/iphone/.test(n))return{icon:'#i-phone',label:'iPhone'};
  if(/ipad/.test(n))return{icon:'#i-tablet',label:'iPad'};
  if(/mac ?book|imac|\bmac\b/.test(n))return{icon:'#i-laptop',label:'Mac'};
  if(/\bwatch\b/.test(n))return{icon:'#i-watch',label:'Watch'};
  if(/nothing-?phone|pixel|galaxy|oneplus|redmi|xiaomi-phone|poco|realme|oppo-|vivo-/.test(n))return{icon:'#i-phone',label:'Phone'};
  if(/^hp[a-z0-9]{4,}|canon|epson|brother|kyocera|officejet|laserjet/.test(n))return{icon:'#i-printer',label:'Printer'};
  if(/vacuum|roborock|dreame|xiaomi-vacuum/.test(n))return{icon:'#i-vacuum',label:'Vacuum'};
  if(/yeelink|yeelight|bulb|lamp|\blight\b/.test(n))return{icon:'#i-bulb',label:'Light'};
  if(/doorbell|ring-|videodoorbell/.test(n))return{icon:'#i-doorbell',label:'Doorbell'};
  if(/homepod|sonos|speaker|audio|gostina|echo-|alexa|yandex-station/.test(n))return{icon:'#i-speaker',label:'Speaker'};
  if(/\btv\b|bravia|aquos|webos|smarttv|samsung-tv|lg-tv/.test(n))return{icon:'#i-tv',label:'TV'};
  if(/router|ax\d|ac\d\d\d\d|asus-wifi|keenetic|mikrotik|mesh|orbi/.test(n))return{icon:'#i-router',label:'Router'};
  if(/laptop|thinkpad|xps|ideapad|desktop|workstation|pc-/.test(n))return{icon:'#i-laptop',label:'PC'};
  if(/android/.test(n))return{icon:'#i-phone',label:'Android'};
  return{icon:'#i-device',label:''};
}

let _devicesCache=[];

async function loadDevices(){
  try{const r=await apiFetch(API+'?action=get-devices');const d=await r.json();
    _devicesCache=d||[];
    renderDevices();
    loadTraffic();
  }catch(e){}
}

function filterDevices(){renderDevices()}

function renderDevices(){
  const rules=(state&&state.device_rules)||{};
  const list=document.getElementById('deviceList');
  const q=(document.getElementById('devSearch')?.value||'').toLowerCase().trim();
  document.getElementById('devCount').textContent=_devicesCache.length;
  const filtered=_devicesCache.filter(dev=>{
    if(!q)return true;
    return (dev.name||'').toLowerCase().includes(q)
      ||(dev.ip||'').includes(q)
      ||(dev.mac||'').toLowerCase().includes(q);
  });
  if(!filtered.length){
    list.innerHTML=q?'<div class="dev-empty">Не найдено по запросу "<b>'+esc(q)+'</b>"</div>':'<div class="dev-empty">Нет подключённых устройств</div>';
    return;
  }
  // Match a device against device_rules either by MAC (preferred — survives
  // DHCP changes) or by IP (legacy rules from before MAC support landed).
  // Backend always normalizes MAC to uppercase, so we only need to check
  // the uppercase form.
  const ruleFor=(dev)=>{
    const macUp=(dev.mac||'').toUpperCase();
    const v=rules[macUp]||rules[dev.ip];
    return v==='vpn'||v==='direct'?v:'auto';
  };
  const groups={direct:[],vpn:[],auto:[]};
  for(const dev of filtered)groups[ruleFor(dev)].push(dev);
  const OPTS=[['auto','Как все'],['vpn','VPN'],['direct','Напрямую']];
  const renderOne=(dev)=>{
    const rule=ruleFor(dev);
    const t=detectDeviceType(dev.name);
    const isUnknown=!dev.name||dev.name==='*';
    const avatarCls=isUnknown?'unknown':(rule==='direct'?'direct':'vpn');
    const title=isUnknown?'Неизвестное устройство':esc(dev.name);
    const typeHint=t.label?` <span style="color:var(--text-dim);font-weight:500">· ${t.label}</span>`:'';
    // Prefer MAC for the rule key — IP can change across DHCP renewals,
    // MAC is fixed to the device.
    const id=esc(dev.mac||dev.ip);
    const seg=OPTS.map(([v,l])=>`<button class="seg-btn${v===rule?' on':''}" data-dev-id="${id}" data-dev-ip="${esc(dev.ip)}" data-dev-route="${v}" aria-pressed="${v===rule}"${_devPending?' disabled':''}>${l}</button>`).join('');
    return `<div class="device">
      <div class="device-avatar ${avatarCls}"><svg class="icon icon-lg"><use href="${t.icon}"/></svg></div>
      <div class="device-info">
        <div class="device-name">${title}${typeHint}</div>
        <div class="device-meta">${esc(dev.ip)} · ${esc(dev.mac)}</div>
      </div>
      <div class="seg" role="group" aria-label="Маршрут: ${title}">${seg}</div>
    </div>`;
  };
  list.innerHTML=[['direct','Всегда напрямую'],['vpn','Всегда через VPN'],['auto','Как все']]
    .filter(([g])=>groups[g].length)
    .map(([g,l])=>`<div class="dev-group-header">${l}<span class="dev-group-count">${groups[g].length}</span></div>`+groups[g].map(renderOne).join(''))
    .join('');
}
let _devPending=false;
async function setDeviceRoute(id,ip,route){
  if(_devPending)return;
  const rules=(state&&state.device_rules)||{};
  const mac=id.toUpperCase();
  _devPending=true;renderDevices();
  const tid=toast.loading('Применяем маршрут…');
  try{
    // A rule may be keyed by MAC or (older/CLI) by IP. Clear the IP one too,
    // otherwise «Как все» would leave it in force.
    if(ip&&ip!==id&&rules[ip]){
      const d=await(await apiFetch(API+'?action=remove-device-route&ip='+ip,{timeoutMs:65000})).json();
      if(d.error)throw new Error(d.error);
      delete rules[ip];
    }
    // The backend soft-restarts the tunnel to apply the rule, hence the long timeout.
    if(route!=='auto'||rules[mac]||rules[id]){
      const r=await apiFetch(API+(route==='auto'?'?action=remove-device-route&ip='+id:'?action=set-device&ip='+id+'&route='+route),{timeoutMs:65000});
      const d=await r.json();
      if(d.error)throw new Error(d.error);
    }
    // Reflect it now; the next /status poll brings the stored rules.
    // A poll may have replaced state (and its rules object) meanwhile.
    const cur=state.device_rules=state.device_rules||{};
    delete cur[ip];delete cur[mac];delete cur[id];
    if(route!=='auto')cur[id.includes(':')?mac:id]=route;
    updateToast(tid,'Маршрут изменён',{type:'success',desc:ip+' → '+({auto:'как все',vpn:'всегда через VPN',direct:'напрямую'}[route])});
  }catch(e){
    updateToast(tid,'Маршрут не изменён',{type:'error',desc:ruErr(e.message)});
  }
  _devPending=false;renderDevices();
  try{await fetchStatus()}catch(_){}
  renderDevices();
}
function fmtSinceShort(ts){
  if(!ts||ts<=0)return '—';
  const d=new Date(ts*1000);
  const now=Date.now()/1000;
  const ago=now-ts;
  if(ago<60)return 'только что';
  if(ago<3600)return 'за '+Math.floor(ago/60)+' мин';
  if(ago<86400)return 'за '+Math.floor(ago/3600)+' ч';
  if(ago<7*86400)return 'за '+Math.floor(ago/86400)+' дн';
  return 'с '+d.toLocaleDateString('ru-RU',{day:'numeric',month:'short'})+' '+d.toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'});
}
async function loadTraffic(){
  try{
    const r=await apiFetch(API+'?action=get-traffic');const d=await r.json();
    const vpnTotal=(d.vpn_dl||0)+(d.vpn_ul||0);
    const dirTotal=(d.dir_dl||0)+(d.dir_ul||0);
    const sessionVpn=document.getElementById('sessionVpn');
    if(sessionVpn)sessionVpn.textContent=fmtBytes(vpnTotal);
    const sessionDirect=document.getElementById('sessionDirect');
    if(sessionDirect)sessionDirect.textContent=fmtBytes(dirTotal);
    const tv=document.getElementById('trafficVpn');
    if(tv)tv.textContent=fmtBytes(vpnTotal);
    const td=document.getElementById('trafficDirect');
    if(td)td.textContent=fmtBytes(dirTotal);
    // Per-chain breakdown tooltips: dl/ul split is more useful than the sum
    // when diagnosing "why is upload so high".
    const statVpn=document.getElementById('statVpn');
    if(statVpn)statVpn.title='Через VPN: ↓ '+fmtBytes(d.vpn_dl||0)+'  ↑ '+fmtBytes(d.vpn_ul||0);
    const statDirect=document.getElementById('statDirect');
    if(statDirect)statDirect.title='Напрямую: ↓ '+fmtBytes(d.dir_dl||0)+'  ↑ '+fmtBytes(d.dir_ul||0);
    const since=document.getElementById('trafficSince');
    if(since){
      since.textContent='учёт '+fmtSinceShort(d.started);
      if(d.started)since.title='Учёт начат '+new Date(d.started*1000).toLocaleString('ru-RU')+'. Переживает рестарты sing-box, сбрасывается только вручную.';
    }
  }catch(e){}
}
async function resetTraffic(){
  if(!await askBox({title:'Обнулить счётчики трафика?',text:'«Через VPN» и «Напрямую» начнутся с нуля.',ok:'Обнулить',danger:true}))return;
  try{
    await apiFetch(API+'?action=reset-traffic');
    toast.success('Счётчики обнулены');
    loadTraffic();
  }catch(e){toast.error('Не удалось обнулить')}
}

// Speed history + sparkline
const SPARK_POINTS=60;
const speedHistory={down:new Array(SPARK_POINTS).fill(0),up:new Array(SPARK_POINTS).fill(0)};
function pushSpeed(down,up){
  speedHistory.down.shift();speedHistory.down.push(down);
  speedHistory.up.shift();speedHistory.up.push(up);
  drawSpark();
}
function drawSpark(){
  const c=document.getElementById('speedSpark');if(!c)return;
  const dpr=window.devicePixelRatio||1;
  const rect=c.getBoundingClientRect();
  const w=rect.width,h=rect.height;
  if(c.width!==w*dpr||c.height!==h*dpr){c.width=w*dpr;c.height=h*dpr}
  const ctx=c.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);
  ctx.clearRect(0,0,w,h);
  const max=Math.max(1,...speedHistory.down,...speedHistory.up);
  const drawLine=(arr,stroke,fill)=>{
    ctx.beginPath();
    arr.forEach((v,i)=>{
      const x=i*(w/(SPARK_POINTS-1));
      const y=h-(v/max)*(h-4)-2;
      if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);
    });
    if(fill){
      const grad=ctx.createLinearGradient(0,0,0,h);
      grad.addColorStop(0,fill);grad.addColorStop(1,'transparent');
      const x2=(SPARK_POINTS-1)*(w/(SPARK_POINTS-1));
      ctx.lineTo(x2,h);ctx.lineTo(0,h);ctx.closePath();
      ctx.fillStyle=grad;ctx.fill();
      ctx.beginPath();
      arr.forEach((v,i)=>{
        const x=i*(w/(SPARK_POINTS-1));
        const y=h-(v/max)*(h-4)-2;
        if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);
      });
    }
    ctx.strokeStyle=stroke;ctx.lineWidth=1.5;ctx.lineJoin='round';ctx.stroke();
  };
  drawLine(speedHistory.down,'#34d399','rgba(52,211,153,0.25)');
  drawLine(speedHistory.up,'#5e6ad2',null);
}

// Speed monitor — was a direct WebSocket from the browser to sing-box's
// Clash API on :9090, which required leaking the API token to every LAN
// device that hit /status. Now polled through CGI: clash_api binds to
// 127.0.0.1, the secret never leaves the router, and the CGI shim returns
// one snapshot per call. Loses ~1s of granularity vs the WS push.
let _speedTimer=null;
async function speedTick(){
  if(document.hidden) return;
  try{
    const r=await apiFetch(API+'?action=traffic-poll');
    const d=await r.json();
    const down=d.down||0, up=d.up||0;
    document.getElementById('speedDown').textContent=fmtSpeed(down);
    document.getElementById('speedUp').textContent=fmtSpeed(up);
    pushSpeed(down,up);
  }catch(e){}
}
function startSpeedMonitor(){
  if(_speedTimer) clearInterval(_speedTimer);
  speedTick();
  _speedTimer=setInterval(speedTick,1000);
}
function stopSpeedMonitor(){
  if(_speedTimer){ clearInterval(_speedTimer); _speedTimer=null; }
}
// Compatibility shims — older code paths reference these.
let speedWs=null;
// Polling pauses when tab is hidden — saves battery on iPhone where the
// page may sit in a background tab for hours. visibilitychange triggers
// an immediate refresh on return so data isn't stale.
setInterval(()=>{if(!document.hidden)loadTraffic()},5000);

// Logs
const LOG_FILTER_HINTS={
  conn:'Соединения через VPN и напрямую, ошибки и события EclipVPN — без потока DNS-запросов.',
  all:'Все события: соединения через VPN, напрямую, DNS-запросы и системные сообщения роутера.',
  vpn:'Соединения через VPN-туннель — эти запросы видны сайтам как иностранный IP.',
  direct:'Соединения напрямую, минуя VPN. Сюда идут российские сайты и исключения — это ускоряет их загрузку и сохраняет домашний IP для них.',
  error:'Только реальные сбои. Фоновый шум — таймауты к Яндексу через провайдера и DNS-всплески Apple — отфильтрован, чтобы не пугать без причины.',
  incidents:'История важных событий: сбои связи, смены сервера, проблемы у провайдера, обновления EclipVPN. Число в красном кружке — только сбои.',
  dns:'DNS-запросы: домен → IP. Полезно если сайт «не открывается» — здесь видно, переводится ли имя в адрес и как.',
  flow:'Действия EclipVPN: запуск/остановка, переключения серверов, обновления подписки, события автоматики. Это лог утилиты, а не трафик.'
};
function setLogFilter(f,el){
  currentLogFilter=f;
  _lastLogSig='';
  document.querySelectorAll('.log-filter').forEach(b=>b.classList.remove('active'));
  el.classList.add('active');
  const hint=document.getElementById('logFilterHint');
  if(hint)hint.textContent=LOG_FILTER_HINTS[f]||'';
  const list=document.getElementById('logList');
  if(list)list.classList.add('updating');
  loadLogs().finally(()=>{if(list)list.classList.remove('updating')});
}
let liveMode=true,liveTimer=null;
function toggleLive(){
  liveMode=!liveMode;
  const b=document.getElementById('liveBtn');
  b.classList.toggle('paused',!liveMode);
  b.textContent=liveMode?'Live':'Пауза';
  if(liveMode){startLive()}else{stopLive()}
}
function startLive(){
  stopLive();
  if(!document.getElementById('sec-logs').classList.contains('active'))return;
  liveTimer=setInterval(loadLogs,2500);
}
function stopLive(){if(liveTimer){clearInterval(liveTimer);liveTimer=null}}

function groupLogs(entries){
  // Merge consecutive identical entries (same route + dst)
  const groups=[];
  for(const e of entries){
    const last=groups[groups.length-1];
    if(last&&last.route===e.route&&last.dst===e.dst){
      last.count++;last.time=e.time;
    }else{
      groups.push({...e,count:1});
    }
  }
  return groups;
}

let _lastLogSig='',_logLoading=false;
async function loadLogs(){
  if(_logLoading)return;
  _logLoading=true;
  // Incidents are stored separately (not in singbox.log) — fetch via the
  // dedicated endpoint and render with the incident-card style. Updates
  // incidentStats too so server-list badges stay in sync.
  if(currentLogFilter==='incidents'){
    try{
      const r=await apiFetch(API+'?action=get-incidents');
      const d=await r.json();
      incidentStats={};
      (d.stats||[]).forEach(s=>{ if(s.host) incidentStats[s.host]=s; });
      updateIncidentsBadge(d.incidents||[]);
      if(state&&state.servers)renderServers(state.servers,state.selected);
      renderIncidentsInLog(d.incidents||[]);
      const list=(d.incidents||[]);
      _lastLogSig='INC:'+list.length;
      // Drop the previous filter's counters: they describe connections.
      document.getElementById('logCount').textContent=list.length;
      document.getElementById('logStats').innerHTML='';
    }catch(e){}
    _logLoading=false;
    return;
  }
  try{
    const asked=currentLogFilter;
    const r=await apiFetch(API+'?action=get-log&lines=200&filter='+asked);
    const d=await r.json();
    // The user picked another filter meanwhile: this answer is not for it.
    if(asked!==currentLogFilter){setTimeout(loadLogs,0);return}
    const list=document.getElementById('logList');
    if(!list){_logLoading=false;return}

    // Empty case — render once, skip repeat. Message depends on filter
    // and VPN state: "no errors" is good news, "no connections" only makes
    // sense when VPN is actually off.
    if(!d.length){
      const emptySig='EMPTY:'+currentLogFilter;
      if(_lastLogSig!==emptySig){
        const f=currentLogFilter;
        const running=state&&state.running;
        let msg;
        if(!running){
          msg='Журнал пуст. Включите VPN — здесь появятся соединения.';
        }else if(f==='error'){
          msg='Ошибок нет — всё работает штатно.';
        }else if(f==='vpn'){
          msg='Через VPN сейчас нет активных соединений.';
        }else if(f==='direct'){
          msg='Напрямую сейчас нет активных соединений.';
        }else if(f==='dns'){
          msg='DNS-запросов в буфере нет — попробуйте обновить страницу или открыть сайт.';
        }else if(f==='flow'){
          msg='Системных событий EclipVPN нет.';
        }else{
          msg='Записей в буфере нет.';
        }
        list.innerHTML='<div class="log-empty"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 9h8M8 13h8M8 17h5"/></svg>'+esc(msg)+'</div>';
        _lastLogSig=emptySig;
      }
      const ls=document.getElementById('logStats');if(ls&&ls.innerHTML!=='')ls.innerHTML='';
      const lc=document.getElementById('logCount');if(lc&&lc.textContent!=='0')lc.textContent='0';
      _logLoading=false;
      return;
    }

    const grouped=groupLogs(d);
    // Signature: filter + (route|dst|count) for each grouped line. Time excluded so second-by-second ticks don't cause redraws.
    const sig=currentLogFilter+'|'+grouped.length+':'+grouped.map(e=>e.route+e.dst+e.count).join('~');
    if(sig===_lastLogSig){
      // Data identical — only update total count badge (cheap)
      const lc=document.getElementById('logCount');
      if(lc&&lc.textContent!==String(d.length))lc.textContent=d.length;
      _logLoading=false;
      return;
    }
    _lastLogSig=sig;

    let vpn=0,direct=0,err=0;
    const icons={vpn:'#i-lock',direct:'#i-globe',error:'#i-x',dns:'#i-search',flow:'#i-gear',xray:'#i-link'};
    const labels={vpn:'VPN',direct:'НАПРЯМУЮ',error:'ОШИБКА',dns:'DNS',flow:'СИСТЕМА',xray:'XRAY'};
    const wasAtBottom=list.scrollTop+list.clientHeight>=list.scrollHeight-40;
    const html=grouped.map(e=>{
      if(e.route==='vpn')vpn+=e.count;if(e.route==='direct')direct+=e.count;if(e.route==='error')err+=e.count;
      const time=e.time?(e.time.includes(' ')?e.time.split(' ').pop():e.time):'';
      const dup=e.count>1?`<span class="log-dup-count">×${e.count}</span>`:'';
      return `<div class="log-line log-${esc(e.route)}${e.count>1?' log-dup':''}">`
        +`<span class="log-time">${esc(time.slice(0,8))}</span>`
        +`<span class="log-icon"><svg class="icon icon-sm"><use href="${icons[e.route]||'#i-globe'}"/></svg></span>`
        +`<span class="log-label">${labels[e.route]||'?'}</span>`
        +`<span class="log-msg">${esc(e.dst||'')}</span>`
        +`${dup}</div>`;
    }).join('');
    list.innerHTML=html;
    if(wasAtBottom)list.scrollTop=list.scrollHeight;
    document.getElementById('logCount').textContent=d.length;
    document.getElementById('logStats').innerHTML=`<span>VPN <b>${vpn}</b></span><span>Напрямую <b>${direct}</b></span>${err?`<span style="color:var(--red)">Ошибок <b>${err}</b></span>`:''}`;
  }catch(e){}
  finally{_logLoading=false}
}
async function clearLog(){
  if(currentLogFilter==='incidents'){
    if(!await askBox({title:'Очистить всю историю событий?',ok:'Очистить',danger:true}))return;
    try{await apiFetch(API+'?action=clear-incidents');_lastLogSig='';toast.success('История событий очищена');loadIncidents();loadLogs()}
    catch(e){toast.error('Ошибка')}
    return;
  }
  try{await apiFetch(API+'?action=clear-log');_lastLogSig='';toast.success('Журнал очищен');loadLogs()}catch(e){toast.error('Ошибка')}
}
async function exportLog(){
  try{const r=await apiFetch(API+'?action=get-log&lines=1000&filter=all');const d=await r.json();
    let txt='EclipVPN — журнал — '+new Date().toLocaleString('ru')+'\n'+'='.repeat(60)+'\n\n';
    const labels={vpn:'[VPN]    ',direct:'[DIRECT] ',error:'[ERROR]  ',dns:'[DNS]    ',flow:'[FLOW]   ',xray:'[XRAY]   '};
    d.forEach(e=>{txt+=`${e.time||''} ${labels[e.route]||''}${e.dst||''}\n`});
    txt+=`\nВсего записей: ${d.length}`;
    // Safari needs the link in the DOM and a deferred revoke; otherwise the
    // download may race with revoke and produce an empty file.
    const a=document.createElement('a'),u=URL.createObjectURL(new Blob([txt],{type:'text/plain'}));
    a.href=u;a.download='eclipvpn-log-'+new Date().toISOString().slice(0,10)+'.txt';
    document.body.appendChild(a);a.click();a.remove();
    setTimeout(()=>URL.revokeObjectURL(u),1000);
    toast.success('Журнал скачан');
  }catch(e){toast.error('Ошибка скачивания')}
}

// Quick diagnose
// Diagnostics
function checkAction(c){
  // Map a healthcheck row to a fix-action when it's warn/error
  if(c.status==='ok')return null;
  const n=(c.name||'').toLowerCase();
  if(n==='лог')return{label:'Очистить журнал',fn:'hcClearLog()'};
  if(n==='ошибки')return{label:'Открыть журнал ошибок',fn:'hcOpenErrors()'};
  if(n==='xray'||n==='sing-box')return{label:'Перезапустить EclipVPN',fn:'doRestart()'};
  return null;
}
async function hcClearLog(){
  try{await apiFetch(API+'?action=clear-log');toast.success('Журнал очищен');_lastLogSig='';runHealthcheck()}
  catch(e){toast.error('Ошибка очистки')}
}
function hcOpenErrors(){
  const tab=document.querySelector('.tab[data-tab="logs"]');
  showTab('logs',tab);
  const errFilter=document.querySelector('.log-filter[data-filter="error"]');
  if(errFilter)setLogFilter('error',errFilter);
}
async function runHealthcheck(){
  const b=document.getElementById('hcBtn');b.disabled=true;b.innerHTML='<span class="spinner"></span> Проверяем…';
  document.getElementById('hcResults').innerHTML='<div style="color:var(--text-dim);font-size:12px;padding:20px;text-align:center"><span class="spinner"></span> Выполняем 26 проверок…</div>';
  try{const r=await apiFetch(API+'?action=healthcheck',{timeoutMs:65000});const d=await r.json();
    let ok=0,warn=0,err=0;
    const html=d.map(c=>{
      if(c.status==='ok')ok++;else if(c.status==='warn')warn++;else err++;
      const icon=c.status==='ok'?'#i-check':c.status==='warn'?'#i-alert':'#i-x';
      const act=checkAction(c);
      const clickable=act?' check-action':'';
      const clickAttr=act?` onclick="event.stopPropagation();${act.fn}"`:'';
      const btn=act?`<button class="check-act-btn" onclick="event.stopPropagation();${act.fn}">${esc(act.label)} →</button>`:'';
      return `<div class="check check-${esc(c.status)}${clickable}"${clickAttr}>`
        +`<div class="check-icon"><svg class="icon icon-sm"><use href="${icon}"/></svg></div>`
        +`<div class="check-body"><div class="check-name">${esc(c.name)}</div>`
        +`<div class="check-detail">${esc(c.detail)}</div>`
        +btn+`</div></div>`;
    }).join('')+`<div class="check-summary">
      <div class="summary-item" style="color:var(--green)"><svg class="icon"><use href="#i-check"/></svg> <span class="summary-num">${ok}</span> успешно</div>
      <div class="summary-item" style="color:var(--yellow)"><svg class="icon"><use href="#i-alert"/></svg> <span class="summary-num">${warn}</span> предупр.</div>
      <div class="summary-item" style="color:var(--red)"><svg class="icon"><use href="#i-x"/></svg> <span class="summary-num">${err}</span> ошибок</div>
    </div>`;
    document.getElementById('hcResults').innerHTML=html;
  }catch(e){document.getElementById('hcResults').innerHTML='<div style="color:var(--red);padding:16px;text-align:center">Ошибка проверки</div>'}
  b.disabled=false;b.textContent='Запустить';
}

// Schedule
async function toggleSchedule(enable){
  // Same visual-from-action pattern as setAutoUpdate. Earlier code called
  // loadSchedule() (GET, cacheable) right after the action; some browsers
  // returned stale state and reverted the toggle, so the user had to click
  // twice to actually disable.
  const tg=document.getElementById('schedToggle');
  const body=document.getElementById('schedBody');
  const st=document.getElementById('schedStatus');
  if(tg) tg.disabled=true;
  body.classList.toggle('disabled',!enable);
  try{
    if(enable){
      await saveScheduleInner();
    }else{
      await apiFetch(API+'?action=schedule&mode=disable');
      if(st){ st.className='setting-status'; st.textContent='Выключено'; }
      toast.info('Расписание отключено');
    }
    if(tg) tg.checked=!!enable;
  }catch(e){
    if(tg) tg.checked=!enable;
    body.classList.toggle('disabled',enable);
    toast.error('Ошибка','Не удалось сохранить расписание');
  }finally{
    if(tg) tg.disabled=false;
  }
}
async function saveSchedule(){
  if(!document.getElementById('schedToggle').checked)return;
  try{ await saveScheduleInner(); }catch(e){ toast.error('Ошибка сохранения'); }
}
async function saveScheduleInner(){
  const on=document.getElementById('schedOn').value,off=document.getElementById('schedOff').value;
  if(!on||!off){ toast.error('Укажите время'); throw new Error('time-missing'); }
  await apiFetch(API+'?action=schedule&on='+on+'&off='+off);
  const st=document.getElementById('schedStatus');
  if(st){ st.className='setting-status on'; st.textContent='Активно: '+on+' — '+off; }
  toast.success('Расписание обновлено',on+' — '+off);
}
async function loadSchedule(){
  // Cache-busted GET — browser was caching the previous answer and the
  // toggle would render with stale state on tab switch.
  try{const r=await apiFetch(API+'?action=schedule&_='+Date.now());const d=await r.json();
    const st=document.getElementById('schedStatus');
    const tg=document.getElementById('schedToggle');
    const body=document.getElementById('schedBody');
    if(tg) tg.checked=!!d.enabled;
    body.classList.toggle('disabled',!d.enabled);
    if(st){
      if(d.enabled){st.className='setting-status on';st.textContent='Активно: '+d.on+' — '+d.off}
      else{st.className='setting-status';st.textContent='Выключено'}
    }
    if(d.on)document.getElementById('schedOn').value=d.on;
    if(d.off)document.getElementById('schedOff').value=d.off;
  }catch(e){}
}
// --- Self-update (update.sh). check → «Обновить до X» → background worker,
// polled via update-status. The worker runs detached on the router (uhttpd
// kills a CGI at 60s), restarts the VPN onto the new code and rolls back by
// itself if the tunnel does not come up.
let _updPoll=null;
// Release notes: the small Markdown subset we write (headings, bullets, bold,
// code, links as text). Escaped FIRST, so the text can only yield these tags.
function renderNotes(md){
  const inline=t=>t
    .replace(/`([^`]+)`/g,'<code>$1</code>')
    .replace(/\*\*(.+?)\*\*/g,'<b>$1</b>')
    .replace(/\[([^\]]+)\]\([^)\s]+\)/g,'$1');
  let out='',list=false;
  for(const raw of esc(md).split(/\r?\n/)){
    const line=raw.trim(),li=line.match(/^[-*]\s+(.*)/),h=line.match(/^#{1,6}\s+(.*)/);
    if(!!li!==list){out+=li?'<ul>':'</ul>';list=!!li}
    if(li)out+='<li>'+inline(li[1])+'</li>';
    else if(h)out+='<p><b>'+inline(h[1])+'</b></p>';
    else if(line)out+='<p>'+inline(line)+'</p>';
  }
  return out+(list?'</ul>':'');
}
function _updBox(html){const el=document.getElementById('updResult');if(!el)return;el.style.display=html?'block':'none';el.innerHTML=html||''}
async function checkUpdate(){
  const b=document.getElementById('updCheckBtn');
  if(b){b.disabled=true;b.innerHTML='<span class="spinner"></span> Проверяем';}
  try{
    const r=await apiFetch(API+'?action=update-check');const d=await r.json();
    if(d.error){_updBox('<div style="color:var(--red);font-size:12px">'+esc(d.error)+'</div>');return}
    if(!d.available){
      _updBox('<div style="font-size:12px;color:var(--text-dim)">Установлена последняя версия: <b>v'+esc(d.current)+'</b>'+(d.latest?' (на GitHub: '+esc(d.latest)+')':'')+'</div>');
      return;
    }
    const link=/^https:\/\/github\.com\//.test(d.url||'')?'<a href="'+esc(d.url)+'" target="_blank" rel="noopener" class="footer-link">Открыть на GitHub</a>':'';
    const notes=(d.notes?'<div class="upd-notes">'+renderNotes(d.notes)+'</div>':'')+(link?'<div style="font-size:12px;margin-bottom:6px">'+link+'</div>':'');
    _updBox('<div style="font-size:12.5px">Доступна версия <b>'+esc(d.latest)+'</b> (сейчас v'+esc(d.current)+')</div>'+notes
      +'<button class="btn btn-primary btn-sm" style="margin-top:6px" data-tag="'+esc(d.latest)+'" onclick="startUpdate(this.dataset.tag)">Обновить до '+esc(d.latest)+'</button>');
  }catch(e){_updBox('<div style="color:var(--red);font-size:12px">Ошибка проверки</div>')}
  finally{if(b){b.disabled=false;b.textContent='Проверить';}}
}
async function startUpdate(tag){
  if(!await askBox({title:'Обновить EclipVPN до '+tag+'?',ok:'Обновить',text:'VPN перезапустится — интернет пропадёт на 10–30 секунд. Если после обновления VPN не поднимется, автоматически вернётся прежняя версия.'}))return;
  try{
    const r=await apiFetch(API+'?action=self-update&tag='+encodeURIComponent(tag));const d=await r.json();
    if(d.error){toast.error('Обновление не запущено',d.error);return}
    if(d.status==='up_to_date'){toast.info('Уже установлена последняя версия');return}
    _updBox('<div style="font-size:12.5px"><span class="spinner"></span> <span id="updPhase">Запуск…</span></div>');
    if(_updPoll)clearInterval(_updPoll);
    _updPoll=setInterval(pollUpdate,2500);
  }catch(e){toast.error('Обновление не запущено')}
}
const _UPD_DONE={done:1,failed:1,rolled_back:1};
// Re-attach to an update still running (page reloaded or reopened mid-update).
async function resumeUpdate(){
  if(_updPoll)return;
  try{
    const r=await apiFetch(API+'?action=update-status');const d=await r.json();
    if(!d.phase||d.phase==='idle'||_UPD_DONE[d.phase])return;
    _updBox('<div style="font-size:12.5px"><span class="spinner"></span> <span id="updPhase">'+esc(d.message||'Обновление…')+'</span></div>');
    _updPoll=setInterval(pollUpdate,2500);
  }catch(e){}
}
async function pollUpdate(){
  let d;
  // The VPN restart drops the router's web server for a moment — a failed
  // poll is expected mid-update, just try again on the next tick.
  try{const r=await apiFetch(API+'?action=update-status');d=await r.json()}catch(e){return}
  const ph=document.getElementById('updPhase');
  if(ph&&d.message)ph.textContent=d.message;
  if(!_UPD_DONE[d.phase])return;
  clearInterval(_updPoll);_updPoll=null;
  if(d.phase==='done'){
    _updBox('<div style="font-size:12.5px;color:var(--green)">'+esc(d.message)+'. Страница перезагрузится…</div>');
    toast.success('EclipVPN обновлён',d.target);
    // index.html itself was replaced — reload past the browser cache.
    setTimeout(()=>{location.reload()},2500);
  }else{
    _updBox('<div style="font-size:12.5px;color:var(--red)">'+esc(d.message||'Обновление не удалось')+'</div>');
    toast.error(d.phase==='rolled_back'?'Обновление откатено':'Обновление не удалось',d.message||'');
  }
}
async function loadSystemInfo(){
  try{const r=await apiFetch(API+'?action=system-info');const d=await r.json();
    const el=document.getElementById('sysInfo');if(!el)return;
    const fmtKB=(kb)=>kb<1024?kb+' КБ':(kb/1024)>=1024?(kb/1048576).toFixed(2)+' ГБ':(kb/1024).toFixed(1)+' МБ';
    const memUsedKB=(d.mem_total_kb||0)-(d.mem_avail_kb||0);
    const memPct=d.mem_total_kb?Math.round(memUsedKB/d.mem_total_kb*100):0;
    const flashPct=d.flash_total_kb?Math.round((d.flash_used_kb||0)/d.flash_total_kb*100):0;
    const memCls=memPct>90?'err':memPct>70?'warn':'';
    const flashCls=flashPct>90?'err':flashPct>80?'warn':'';
    const rows=[
      ['EclipVPN','v'+(d.eclipvpn||'—')],
      ['Сборка',d.build||'—'],
      ['xray',d.xray||'—'],
      ['sing-box',d.singbox||'—'],
      ['Прошивка',d.openwrt||'—'],
      ['Архитектура',d.arch||'—'],
      ['Нагрузка',d.load||'—'],
      ['Роутер работает',fmtUp(d.sys_uptime||0)]
    ];
    const rowsHtml=rows.map(([l,v])=>`<div class="sys-row"><span class="sys-row-label">${esc(l)}</span><span class="sys-row-val" title="${esc(v)}">${esc(v)}</span></div>`).join('');
    el.innerHTML=rowsHtml
      +`<div class="sys-bar" style="grid-column:1/-1">
          <div class="sys-bar-label"><span>Память</span><span><b>${fmtKB(memUsedKB)}</b> / ${fmtKB(d.mem_total_kb||0)}</span></div>
          <div class="sys-bar-track"><div class="sys-bar-fill ${memCls}" style="width:${memPct}%"></div></div>
        </div>`
      +`<div class="sys-bar" style="grid-column:1/-1">
          <div class="sys-bar-label"><span>Флеш-память</span><span><b>${fmtKB(d.flash_used_kb||0)}</b> / ${fmtKB(d.flash_total_kb||0)}</span></div>
          <div class="sys-bar-track"><div class="sys-bar-fill ${flashCls}" style="width:${flashPct}%"></div></div>
        </div>`;
  }catch(e){
    const el=document.getElementById('sysInfo');
    if(el)el.innerHTML='<div style="color:var(--red);font-size:12px;padding:12px 0">Ошибка загрузки</div>';
  }
}

async function setAutoUpdate(mode){
  // Visually update toggle synchronously and lock it during the round-trip.
  // Earlier version called loadAutoUpdate() (no await) after the action,
  // and browsers occasionally served the cached GET reply — leaving the
  // toggle stuck in its previous position even though the backend had
  // applied the change. Now we set the visual state from the action
  // result directly and only refetch as a finalizer.
  const tg=document.getElementById('autoUpdateToggle');
  const st=document.getElementById('autoUpdateStatus');
  if(tg) tg.disabled=true;
  try{
    await apiFetch(API+'?action=auto-update&mode='+mode);
    const enabled=(mode==='enable');
    if(tg) tg.checked=enabled;
    if(st){
      st.className=enabled?'setting-status on':'setting-status';
      st.textContent=enabled?'Включено — каждый день в 3:00':'Выключено';
    }
    toast.success(enabled?'Автообновление включено':'Автообновление выключено');
  }catch(e){
    if(tg) tg.checked=(mode!=='enable');  // revert visual on failure
    toast.error('Ошибка','Не удалось сохранить автообновление');
  }finally{
    if(tg) tg.disabled=false;
  }
}
async function loadAutoUpdate(){
  // Cache-buster: same problem as above could leave us reading a stale
  // copy of the toggle state on tab switch.
  try{const r=await apiFetch(API+'?action=auto-update&_='+Date.now());const d=await r.json();
    const st=document.getElementById('autoUpdateStatus');
    const tg=document.getElementById('autoUpdateToggle');
    if(tg) tg.checked=!!d.auto_update;
    if(st){
      if(d.auto_update){st.className='setting-status on';st.textContent='Включено — каждый день в 3:00'}
      else{st.className='setting-status';st.textContent='Выключено'}
    }
  }catch(e){}
}

// Backup
async function downloadBackup(){
  try{
    const r=await apiFetch(API+'?action=backup');const d=await r.json();
    const a=document.createElement('a'),u=URL.createObjectURL(new Blob([JSON.stringify(d,null,2)],{type:'application/json'}));
    a.href=u;a.download='eclipvpn-backup-'+new Date().toISOString().slice(0,10)+'.json';
    document.body.appendChild(a);a.click();a.remove();
    setTimeout(()=>URL.revokeObjectURL(u),1000);
    toast.success('Бэкап скачан');
  }catch(e){toast.error('Ошибка скачивания')}
}
async function restoreBackup(event){
  const f=event.target.files[0];if(!f)return;
  if(f.size>65536){toast.error('Файл слишком большой');event.target.value='';return}
  const t=await f.text();
  // Validate it's valid JSON with the expected shape before sending to the
  // router — saves a round-trip and prevents writing garbage to config.
  let parsed;
  try{parsed=JSON.parse(t)}
  catch(e){toast.error('Неверный формат файла');event.target.value='';return}
  if(!parsed||typeof parsed.config!=='object'){toast.error('Не похоже на бэкап EclipVPN');event.target.value='';return}
  if(!await askBox({title:'Восстановить настройки из файла?',ok:'Восстановить',danger:true,text:'Текущие настройки (подписка, режим, исключения, маршруты устройств) будут заменены содержимым файла. Если VPN запущен, он перезапустится с новыми настройками.'})){
    event.target.value='';return;
  }
  try{
    const r=await apiFetch(API+'?action=restore',{method:'POST',body:t,timeoutMs:90000});
    const d=await r.json().catch(()=>({}));
    if(d&&d.error){toast.error('Ошибка восстановления',d.error);}
    // applied=true → the live tunnel was restarted with the restored config.
    // applied=false → nothing was running (e.g. a fresh router): servers.json
    // isn't part of a backup, so the user must Update+Start to pull servers.
    else if(d&&d.applied){toast.success('Настройки восстановлены','VPN перезапущен');fetchStatus();}
    else{toast.success('Настройки восстановлены','Нажмите «Обновить», затем «Включить» — серверы подписки подтянутся');fetchStatus();}
  }catch(e){toast.error('Ошибка восстановления')}
  event.target.value='';
}

// Theme — 3-state: auto → light → dark → auto
const THEME_ORDER=['auto','light','dark'];
const THEME_ICONS={auto:'#i-auto',light:'#i-sun',dark:'#i-moon'};
const THEME_LABELS={auto:'Авто',light:'Светлая',dark:'Тёмная'};
function applyTheme(pref){
  const sysLight=window.matchMedia('(prefers-color-scheme: light)').matches;
  const effective=pref==='auto'?(sysLight?'light':'dark'):pref;
  // Disable transitions for one frame so header/cards/etc snap together,
  // not at 200ms intervals — see CSS rule for html.theme-switching.
  const root=document.documentElement;
  root.classList.add('theme-switching');
  if(effective==='light')root.setAttribute('data-theme','light');
  else root.removeAttribute('data-theme');
  requestAnimationFrame(()=>requestAnimationFrame(()=>root.classList.remove('theme-switching')));
  const btn=document.getElementById('themeBtn');
  if(btn){btn.innerHTML='<svg class="icon"><use href="'+THEME_ICONS[pref]+'"/></svg>';btn.title='Тема: '+THEME_LABELS[pref]+' (клик: переключить)'}
}
function toggleTheme(){
  const cur=localStorage.getItem('eclipvpn-theme')||'auto';
  const next=THEME_ORDER[(THEME_ORDER.indexOf(cur)+1)%THEME_ORDER.length];
  localStorage.setItem('eclipvpn-theme',next);
  applyTheme(next);
  toast.info('Тема: '+THEME_LABELS[next]);
}
(function(){
  const saved=localStorage.getItem('eclipvpn-theme');
  // Migrate legacy 'light'/'dark'/null → auto
  if(saved!=='auto'&&saved!=='light'&&saved!=='dark')localStorage.setItem('eclipvpn-theme','auto');
  applyTheme(localStorage.getItem('eclipvpn-theme')||'auto');
  // React to system changes in auto mode
  try{window.matchMedia('(prefers-color-scheme: light)').addEventListener('change',()=>{
    if((localStorage.getItem('eclipvpn-theme')||'auto')==='auto')applyTheme('auto');
  });}catch(e){}
})();

function syncMiniToggle(el){
  // toggleVPN refuses to run while an op is pending and reverts the MAIN
  // checkbox — revert the mini one here too, or they desync until the
  // next status poll.
  if(_vpnPending){el.checked=!el.checked;return}
  const main=document.getElementById('vpnToggle');
  main.checked=el.checked;
  toggleVPN();
}

// Collapsible header: shade on scroll
(function initScrollHeader(){
  const header=document.getElementById('appHeader');
  let ticking=false;
  function update(){
    const y=window.scrollY||document.documentElement.scrollTop||0;
    header.classList.toggle('scrolled',y>40);
    ticking=false;
  }
  window.addEventListener('scroll',()=>{
    if(!ticking){requestAnimationFrame(update);ticking=true}
  },{passive:true});
  update();
  // Mini-toggle visibility — track the main hero toggle, show mini only when
  // the main one has scrolled off-screen. Threshold by scrollY would either
  // overlap (mini shows while main still visible) or hide too long (main
  // already gone but mini still hidden).
  // IMPORTANT: observe the parent <label class="toggle">, not the <input>.
  // The input itself is display:none (custom toggle UX hides the checkbox
  // and styles the surrounding label). getBoundingClientRect on a
  // display:none element returns all zeros, which would make r.bottom<=0
  // true and incorrectly mark the page as "scrolled past hero" on init.
  const mainToggleInput=document.getElementById('vpnToggle');
  const mainToggle=mainToggleInput&&mainToggleInput.closest('.toggle');
  if(mainToggle){
    // Set initial compact state synchronously so there's no flash of
    // mini-toggle before scroll listener fires.
    const setCompact=()=>{
      const r=mainToggle.getBoundingClientRect();
      // Both checks needed: rect of zeros (pre-layout) shouldn't trigger
      // compact, only an actual top-out (bottom strictly less than 0).
      // The hero is deliberately hidden on non-home phone tabs: compact too.
      const heroHidden=!document.body.classList.contains('m-home')&&window.matchMedia('(max-width:840px)').matches;
      header.classList.toggle('compact',heroHidden||(r.height>0&&r.bottom<0));
    };
    window._setCompact=setCompact;
    window.addEventListener('resize',setCompact);
    setCompact();
    // Use a scroll-driven check instead of IntersectionObserver: IO's first
    // async callback can fire with isIntersecting=false on iOS Safari when
    // the page is still settling (dynamic toolbar resizing the visual
    // viewport). getBoundingClientRect after layout is reliable. The cost
    // is one rect read per scroll frame, which is negligible.
    let ticking2=false;
    window.addEventListener('scroll',()=>{
      if(!ticking2){requestAnimationFrame(()=>{setCompact();ticking2=false});ticking2=true}
    },{passive:true});
  }
})();

// Onboarding
let _onboardReturnFocus=null;
// Tab cycling within the onboard dialog. role=dialog + aria-modal=true is
// declared, but without trapping Tab the focus escapes to the page beneath
// — screen-reader users would lose orientation.
function _onboardFocusTrap(e){
  if(e.key!=='Tab')return;
  const o=document.getElementById('onboardOverlay');
  if(!o)return;
  const focusable=o.querySelectorAll('button:not([disabled]),input:not([disabled]),[tabindex="0"]');
  if(!focusable.length)return;
  const first=focusable[0],last=focusable[focusable.length-1];
  if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus()}
  else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus()}
}
function showOnboard(){
  const o=document.getElementById('onboardOverlay');
  if(!o)return;
  // Save focus owner so we can return to it after dialog closes (a11y).
  _onboardReturnFocus=document.activeElement;
  // Reset any leftover error styling from a previous run.
  const desc=document.getElementById('onboardStep2Desc');
  if(desc)desc.style.color='';
  o.classList.add('show');
  setOnboardStep(1);
  setTimeout(()=>document.getElementById('onboardSubUrl').focus(),300);
  o.addEventListener('keydown',_onboardFocusTrap);
}
function _closeOnboard(){
  const o=document.getElementById('onboardOverlay');
  if(o){
    o.classList.remove('show');
    o.removeEventListener('keydown',_onboardFocusTrap);
  }
  if(_onboardReturnFocus&&typeof _onboardReturnFocus.focus==='function'){
    try{_onboardReturnFocus.focus()}catch(e){}
  }
  _onboardReturnFocus=null;
}
function skipOnboard(){
  _closeOnboard();
  localStorage.setItem('eclipvpn-onboarded','1');
}
function setOnboardStep(n){
  document.querySelectorAll('.onboard-pane').forEach(p=>p.classList.remove('active'));
  document.getElementById('onboardStep'+n).classList.add('active');
  document.querySelectorAll('.onboard-steps .step').forEach(s=>{
    const sn=parseInt(s.dataset.step,10);
    s.classList.toggle('active',sn===n);
    s.classList.toggle('done',sn<n);
  });
}
async function onboardNext1(){
  const url=document.getElementById('onboardSubUrl').value.trim();
  if(!url){toast.error('Вставьте ссылку');return}
  if(!/^(https?|vless|vmess|trojan|ss|hysteria2|hy2):\/\//i.test(url)){toast.error('Нужна http(s)-ссылка на подписку или vless:// / vmess:// / trojan:// / ss:// / hysteria2:// сервер');return}
  setOnboardStep(2);
  try{
    // POST sub add — the panel token travels in the body, not the query string
    // (so it doesn't land in the uhttpd access-log / process listing). cmd_sub
    // add fetches + merges the subscription server-side.
    const r=await apiFetch(API+'?action=sub&op=add',{method:'POST',body:JSON.stringify({url}),timeoutMs:90000});const d=await r.json();
    if(d.error){
      document.getElementById('onboardStep2Desc').textContent='Ошибка: '+(d.error||'не удалось загрузить');
      document.getElementById('onboardStep2Desc').style.color='var(--red)';
      setTimeout(()=>setOnboardStep(1),2500);
      return;
    }
    await fetchStatus();
    const cnt=(state&&state.servers)?state.servers.length:0;
    if(cnt===0){
      document.getElementById('onboardStep2Desc').textContent='Не удалось загрузить серверы — проверьте ссылку';
      document.getElementById('onboardStep2Desc').style.color='var(--red)';
      setTimeout(()=>setOnboardStep(1),2500);
      return;
    }
    document.getElementById('onboardStep2Desc').textContent='Найдено серверов: '+cnt;
    setTimeout(()=>setOnboardStep(3),1000);
  }catch(e){
    document.getElementById('onboardStep2Desc').textContent='Ошибка связи';
    setTimeout(()=>setOnboardStep(1),2500);
  }
}
function finishOnboard(){
  localStorage.setItem('eclipvpn-onboarded','1');
  _closeOnboard();
  toast.success('EclipVPN готов к работе','Нажмите переключатель, чтобы подключиться');
}
function maybeShowOnboard(){
  if(localStorage.getItem('eclipvpn-onboarded')==='1')return;
  // Configured = any subscription entry (incl. a manual vless:// server, whose
  // legacy subscription_url mirror is deliberately empty), not just the mirror.
  const configured=state&&(state.subscription_url||((state.subscriptions||[]).length>0));
  if(!configured)showOnboard();
  else localStorage.setItem('eclipvpn-onboarded','1');
}

// Keyboard shortcuts: 1..5 tabs, / search focus, Esc clear filter/close.
// Also: Enter/Space activates any focusable element with role=button (server,
// device, mode-option) — these are <div onclick> for layout reasons but
// should work like real buttons via keyboard.
document.addEventListener('keydown',(e)=>{
  const tag=(e.target.tagName||'').toLowerCase();
  const typing=tag==='input'||tag==='textarea'||tag==='select'||e.target.isContentEditable;
  if((e.key==='Enter'||e.key===' ')&&!typing&&e.target&&e.target.getAttribute&&e.target.getAttribute('role')==='button'){
    e.preventDefault();
    e.target.click();
    return;
  }
  if(e.key==='Escape'){
    // close any open overlay (onboarding) or blur input
    const ob=document.getElementById('onboardOverlay');
    if(ob&&ob.classList.contains('show')){_closeOnboard();return}
    if(typing){e.target.blur();return}
  }
  if(typing||document.getElementById('dlg').open)return;
  if(e.key>='1'&&e.key<='5'){
    const btns=document.querySelectorAll('.tabs .tab');
    const idx=parseInt(e.key,10)-1;
    if(btns[idx]){btns[idx].click();e.preventDefault()}
  }else if(e.key==='/'){
    const cur=document.querySelector('.section.active');
    if(cur){
      const inp=cur.querySelector('input[type="text"],input:not([type]),input[type="search"],input[placeholder*="Поиск"],input[placeholder*="Добавить"],input[placeholder*="например"]');
      if(inp){inp.focus();e.preventDefault()}
    }
  }else if(e.key==='?'){
    toast.info('Горячие клавиши','1–5 вкладки · / поиск · Esc сброс');
  }
});

// Uplink internet indicator: probes the RAW WAN (Yandex + Google anchors)
// server-side via net-check. "whitelist" = only Yandex answers — the uplink
// passes whitelisted hosts only, which explains a failing VPN handshake.
// The probe takes up to ~6s offline, so it runs on its own slow cadence and
// never blocks the 5s status poll.
async function loadNetCheck(){
  try{
    const r=await fetch(API+'?action=net-check');
    const d=await r.json();
    const b=document.getElementById('netBadge');
    if(!b)return;
    const m={
      full:['full','Интернет: есть','Прямой канал работает: Яндекс и Google доступны'],
      whitelist:['whitelist','Интернет: только белые списки','Google напрямую недоступен, Яндекс отвечает — провайдер пропускает только «белые» сайты. Зарубежные VPN-серверы и обновление подписок напрямую могут не работать.'],
      none:['none','Нет интернета','Ни Яндекс, ни Google не отвечают — канал провайдера не работает']
    }[d.internet];
    if(!m){b.style.display='none';return}
    b.className='net-badge '+m[0];
    b.style.display='inline-flex';
    document.getElementById('netBadgeText').textContent=m[1];
    b.title=m[2];
  }catch(e){}
}
restoreCollapsibles();fetchStatus();loadDomains();loadPresets();loadSchedule();loadAutoUpdate();loadIncidents();startSpeedMonitor();loadNetCheck();
// Skip polling when tab is hidden (battery-friendly).
setInterval(()=>{if(!document.hidden)fetchStatus()},5000);
// Incidents change rarely — refresh every 30s instead of 5s.
setInterval(()=>{if(!document.hidden)loadIncidents()},30000);
// Uplink state changes rarely too — 30s keeps the worst-case 6s probe cheap.
setInterval(()=>{if(!document.hidden)loadNetCheck()},30000);
document.addEventListener('visibilitychange',()=>{
  if(document.hidden){ stopSpeedMonitor(); return; }
  fetchStatus(); loadTraffic(); loadIncidents(); loadNetCheck();
  // Restart the polling loop with a fresh tick on tab return — otherwise
  // the speed widgets show stale numbers for up to 1s.
  startSpeedMonitor();
});
