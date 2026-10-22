import Foundation

enum DevelopmentPage {
    static let html = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OpenCove · Development Controls</title><style>
:root{color-scheme:dark;font:14px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;color:#f2f6f5;background:#0b1010}*{box-sizing:border-box}body{margin:0;padding:32px;max-width:1200px;margin-inline:auto}header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}.brand{display:flex;gap:12px;align-items:center}.mark{height:36px;width:48px;border-radius:6px 6px 18px 18px;background:#73e3bd;color:#081c15;display:grid;place-items:center;font-size:23px;font-weight:600}h1{font-size:21px;margin:0;letter-spacing:-.5px}h2{font-size:14px;margin:0 0 14px}p{margin:5px 0;color:#99aba5;line-height:1.5}.badge{font-size:12px;color:#76e4ba;background:#16382c;border-radius:20px;padding:6px 12px}.preview{border:1px solid #22312b;background:radial-gradient(ellipse at 55% 100%,#314536,#14251d 50%,#0e1715);border-radius:18px;min-height:310px;display:flex;flex-direction:column;align-items:center;position:relative;overflow:hidden;padding:0 24px 28px;margin-bottom:20px}.menubar{height:32px;width:100%;display:flex;justify-content:space-between;color:#c3d4cc;font-size:12px;align-items:center}.native{min-height:248px;display:flex;align-items:flex-start;justify-content:center;width:100%}.native img{max-width:100%;height:auto;display:block;image-rendering:auto}.caption{position:absolute;bottom:12px;color:#8ba99a;font-size:11px}.toolbar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:16px 0}.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}.card{background:#121a17;border:1px solid #26322d;border-radius:14px;padding:20px}button{font:inherit;border:1px solid #34473e;background:#20332a;color:#e1efe7;border-radius:8px;padding:8px 12px;cursor:pointer;transition:background .12s}button:hover{background:#2d493a}button.primary{background:#6de0b1;color:#09271b;border-color:transparent;font-weight:600}button.danger{color:#ffbbb4}input,select{font:inherit;background:#0b120e;color:#e3eee7;border:1px solid #34453c;border-radius:7px;padding:8px;min-width:0}input[type=number]{width:100px}input[type=text]{width:100%}label{display:flex;align-items:center;gap:9px;margin:10px 0;color:#c0d2c8}.row{display:flex;gap:8px;margin-top:10px;align-items:center}.row input[type=text]{flex:1}pre{background:#090f0c;padding:14px;border-radius:8px;max-height:280px;overflow:auto;color:#a7bdb0;font:11px/1.5 ui-monospace,monospace}#error{color:#ffb4ac;white-space:pre-wrap;min-height:20px;margin:10px 0}.facts{display:grid;grid-template-columns:1fr 1fr;gap:10px;color:#8ba89a;font-size:12px}.facts strong{display:block;color:#e5f4eb;font-size:15px;margin-top:4px}.files{list-style:none;padding:0;margin:8px 0;font-size:12px}.files li{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid #26372d}.files button{padding:3px 7px;font-size:11px}details{margin-top:20px}summary{cursor:pointer;color:#94b6a3}.muted{color:#8aa092;font-size:12px}@media(max-width:700px){body{padding:18px}.grid{grid-template-columns:1fr}.preview{padding-inline:10px}.badge{display:none}}
</style></head><body>
<header><div class="brand"><div class="mark">⌒</div><div><h1>OpenCove</h1><p>Native app · Development controls</p></div></div><span class="badge" id="connection">Connecting</span></header>
<div class="preview"><div class="menubar"><span>OpenCove</span><span id="screen-state">Native view</span></div><div class="native"><img id="native-image" alt="Native OpenCove notch rendered from the running app"></div><div class="caption">Live SwiftUI rendering · Actions use the running app’s real services</div></div>
<div class="toolbar"><button class="primary" data-action="expand">Expand notch</button><button data-action="collapse">Collapse notch</button><button data-tab="media">Media</button><button data-tab="calendar">Calendar</button><button data-tab="files">Files</button><button data-tab="timer">Timer</button><button data-action="settings">Open settings</button></div>
<div id="error" role="alert"></div>
<div class="grid">
<section class="card"><h2>Live state</h2><div class="facts"><div>Media<strong id="media-title">—</strong></div><div>Audio output<strong id="output">—</strong></div><div>Battery<strong id="battery">—</strong></div><div>Calendar access<strong id="calendar">—</strong></div></div><div class="toolbar"><button data-action="media.refresh">Refresh media</button><button data-action="system.refresh">Refresh system</button><button data-action="calendar.refresh">Refresh calendar</button></div><p id="service-errors" class="muted"></p></section>
<section class="card"><h2>Timer</h2><p id="timer-state">No timer running</p><div class="row"><label for="seconds">Seconds</label><input id="seconds" type="number" min="1" max="86400" value="30"><button class="primary" id="start-timer">Start timer</button></div><div class="toolbar"><button data-action="timer.pause">Pause timer</button><button data-action="timer.resume">Resume timer</button><button data-action="timer.cancel">Cancel timer</button></div></section>
<section class="card"><h2>Appearance</h2><label><input id="hideWhenIdle" type="checkbox">Hide when idle</label><label><input id="expandOnHover" type="checkbox">Expand on hover</label><label><input id="reduceMotion" type="checkbox">Reduce motion</label><label>Notch width <input id="notchWidth" type="number" min="120" max="400" step="10"></label><button id="save-appearance">Save appearance</button><p class="muted">Changes use the same persisted preferences as native settings.</p></section>
<section class="card"><h2>File tray</h2><p class="muted">Add an existing local file. Removing it from the tray keeps the source file.</p><div class="row"><input id="file-path" type="text" aria-label="File path" placeholder="/absolute/path/to/file"><button id="add-file">Add file</button></div><ul class="files" id="files"></ul><button class="danger" data-action="files.clear">Clear tray</button></section>
<section class="card"><h2>Notification</h2><p class="muted">Post an OpenCove activity through the app’s notification interface.</p><div class="row"><input id="notification-title" type="text" aria-label="Notification title" value="OpenCove is ready"></div><div class="row"><input id="notification-body" type="text" aria-label="Notification message" value="Your activity is in the notch."></div><div class="row"><button id="post-notification">Show notification</button></div></section>
<section class="card"><h2>Verification session</h2><p>This page controls the app that explicitly enabled its local control server. No screen input is automated.</p><p id="window-state" class="muted"></p><button id="reconnect">Reconnect</button><button id="complete-onboarding">Complete first run</button><p class="muted">Permission prompts stay explicit in the native app.</p></section>
</div><details><summary>App state</summary><pre id="state"></pre></details>
<script>
let state=null,lastImage=null,poll=null,serial=Promise.resolve(),epoch=0,controller=new AbortController(),unauthorized=false,closed=false,lastRender=0,transportError=false;
const appearanceKeys=['hideWhenIdle','expandOnHover','reduceMotion','notchWidth'],drafts=new Map();
const readToken=()=>new URLSearchParams(location.hash.slice(1)).get('token')||'';
let token=readToken();
const errorBox=document.getElementById('error');
const connectionChanged=()=>new DOMException('Connection changed','AbortError');
function enqueue(operation){const generation=epoch,next=serial.then(()=>{if(generation!==epoch||closed)throw connectionChanged();return operation()});serial=next.catch(()=>{});return next}
function clearImage(){const image=document.getElementById('native-image');image.onload=null;image.onerror=null;image.removeAttribute('src');image.style.removeProperty('width');if(lastImage)URL.revokeObjectURL(lastImage);lastImage=null}
function clearFiles(){const files=document.getElementById('files');for(const button of files.querySelectorAll('button'))button.onclick=null;files.replaceChildren()}
function setActionsEnabled(enabled){for(const button of document.querySelectorAll('button'))if(button.id!=='reconnect')button.disabled=!enabled;for(const key of appearanceKeys)document.getElementById(key).disabled=!enabled}
function paintAppearance(){for(const key of appearanceKeys){const input=document.getElementById(key),value=drafts.has(key)?drafts.get(key):state?.preferences[key];if(input.type==='checkbox')input.checked=value??false;else input.value=value??''}}
// Only explicit user edits enter drafts. App-derived fields, rows, closures and
// images are cleared together whenever the authenticated connection is retired.
function resetConnection(label='Disconnected',message=''){
 epoch++;controller.abort();controller=new AbortController();clearTimeout(poll);poll=null;state=null;transportError=false;lastRender=0;
 clearImage();clearFiles();setActionsEnabled(false);paintAppearance();
 for(const id of ['media-title','output','battery','calendar'])document.getElementById(id).textContent='—';
 document.getElementById('screen-state').textContent='Native view';document.getElementById('timer-state').textContent='No authenticated state';
 for(const id of ['service-errors','window-state','state'])document.getElementById(id).textContent='';
 document.getElementById('connection').textContent=label;errorBox.textContent=message;
}
function disconnected(message){resetConnection('Disconnected',message);transportError=true}
async function request(path,options={}){
 if(closed)throw connectionChanged();
 if(unauthorized)throw Error('The local token expired. Reopen the URL from opencovectl url.');
 if(!token)throw Error('Open the URL from opencovectl url. Its fragment contains the local access token.');
 const generation=epoch;
 const response=await fetch(path,{...options,cache:'no-store',credentials:'omit',redirect:'error',referrerPolicy:'no-referrer',signal:controller.signal,headers:{...options.headers,'X-OpenCove-Token':token}});
 if(generation!==epoch||closed)throw connectionChanged();
 if(response.status===401){unauthorized=true;resetConnection('Token expired','The local token expired. Reopen the URL from opencovectl url.');throw connectionChanged()}
 if(!response.ok){
  let detail;try{detail=await response.json()}catch{detail={}}
  if(generation!==epoch||closed)throw connectionChanged();
  const error=Error(detail.error||('HTTP '+response.status));error.status=response.status;throw error;
 }
 return response;
}
async function render(force=false){
 if(document.hidden||(!force&&Date.now()-lastRender<5000))return;
 const generation=epoch,response=await request('/render?surface=notch'),blob=await response.blob();
 if(generation!==epoch||closed)return;
 const next=URL.createObjectURL(blob),image=document.getElementById('native-image');
 image.onload=()=>{if(generation===epoch&&!closed)image.style.width=image.naturalWidth+'px'};image.src=next;
 if(lastImage)URL.revokeObjectURL(lastImage);lastImage=next;lastRender=Date.now();
}
async function renderPreview(force=false){
 const generation=epoch;
 try{await render(force)}catch(error){
  // A busy/failed preview is separate from a fresh authenticated state. A
  // transport failure still retires the complete connection below.
  if(generation===epoch&&!closed&&(error.status===409||error.status===500)){clearImage();errorBox.textContent='Native preview: '+error.message;return}
  throw error;
 }
}
async function readState(force=false){const generation=epoch,response=await request('/state'),next=await response.json();if(generation!==epoch||closed)return;state=next;if(transportError){errorBox.textContent='';transportError=false}paint();await renderPreview(force)}
async function command(action,values={}){
 const generation=epoch;
 return enqueue(async()=>{
  if(!state||unauthorized||!token)throw Error('Wait for a fresh authenticated app state before sending a command.');
  try{errorBox.textContent='';const response=await request('/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...values,action})});const next=await response.json();if(generation!==epoch||closed)throw connectionChanged();if(action==='preferences')for(const [key,value] of drafts)if(Object.hasOwn(values.values||{},key)&&(key==='notchWidth'?Number(value):value)===values.values[key])drafts.delete(key);state=next;paint();await renderPreview(true)}
  catch(error){if(generation===epoch&&!closed&&error.name!=='AbortError'){errorBox.textContent=error.message;if(!unauthorized){try{await readState()}catch(readError){if(generation===epoch&&!closed&&readError.name!=='AbortError')disconnected(readError.message)}}}throw error}
 });
}
window.opencove={command,getState:()=>state};
function paint(){
 if(!state||closed||unauthorized)return;
 document.getElementById('connection').textContent='Connected';document.getElementById('screen-state').textContent=(state.expanded?'Expanded':'Compact')+' · '+state.tab;
 document.getElementById('media-title').textContent=state.media.available?state.media.title||'Media available':'Nothing playing';document.getElementById('output').textContent=state.system.outputDevice||'Unavailable';document.getElementById('battery').textContent=state.system.hasBattery?state.system.batteryPercent+'%'+(state.system.isCharging?' · Charging':''):'No battery';document.getElementById('calendar').textContent=state.calendarAuthorization;
 document.getElementById('timer-state').textContent=state.timer.remaining>0?Math.ceil(state.timer.remaining)+' seconds · '+(state.timer.running?'Running':'Paused'):'No timer running';document.getElementById('service-errors').textContent=(state.errors||[]).join(' · ');document.getElementById('window-state').textContent=state.nativeWindows.map(w=>w.title+' '+Math.round(w.width)+'×'+Math.round(w.height)).join(' · ');
 paintAppearance();clearFiles();const generation=epoch;document.getElementById('files').replaceChildren(...state.files.map(file=>{const li=document.createElement('li'),text=document.createElement('span'),remove=document.createElement('button');text.textContent=file.name;remove.textContent='Remove';remove.onclick=()=>{if(generation===epoch&&!closed)command('files.remove',{id:file.id}).catch(()=>{})};li.append(text,remove);return li}));document.getElementById('state').textContent=JSON.stringify(state,null,2);setActionsEnabled(true);
}
function schedule(){clearTimeout(poll);if(!closed&&!document.hidden&&!unauthorized&&token)poll=setTimeout(refresh,2500)}
async function refresh(){
 clearTimeout(poll);if(closed||document.hidden||unauthorized||!token)return;
 const generation=epoch;
 try{await enqueue(()=>readState())}catch(error){if(generation===epoch&&!closed&&error.name!=='AbortError'){transportError=true;disconnected(error.message)}}finally{schedule()}
}
function reconnect(){if(closed)return;token=readToken();unauthorized=false;resetConnection(token?'Connecting':'Disconnected',token?'':'Open the URL from opencovectl url to connect.');if(token)refresh()}
for(const key of appearanceKeys)document.getElementById(key).addEventListener('input',event=>drafts.set(key,event.target.type==='checkbox'?event.target.checked:event.target.value));
window.addEventListener('hashchange',reconnect);
window.addEventListener('pagehide',()=>{closed=true;token='';resetConnection()});
window.addEventListener('pageshow',event=>{if(event.persisted){closed=false;reconnect()}});
document.addEventListener('visibilitychange',()=>{if(document.hidden){clearTimeout(poll);controller.abort();controller=new AbortController()}else refresh()});
document.getElementById('reconnect').onclick=reconnect;
for(const button of document.querySelectorAll('[data-action]'))button.onclick=()=>command(button.dataset.action).catch(()=>{});
for(const button of document.querySelectorAll('[data-tab]'))button.onclick=()=>command('selectTab',{tab:button.dataset.tab}).catch(()=>{});
document.getElementById('start-timer').onclick=()=>command('timer.start',{seconds:Number(document.getElementById('seconds').value)}).catch(()=>{});
document.getElementById('add-file').onclick=()=>command('files.add',{paths:[document.getElementById('file-path').value]}).catch(()=>{});
document.getElementById('save-appearance').onclick=()=>command('preferences',{values:{hideWhenIdle:document.getElementById('hideWhenIdle').checked,expandOnHover:document.getElementById('expandOnHover').checked,reduceMotion:document.getElementById('reduceMotion').checked,notchWidth:Number(document.getElementById('notchWidth').value)}}).catch(()=>{});
document.getElementById('post-notification').onclick=()=>command('notification.post',{title:document.getElementById('notification-title').value,body:document.getElementById('notification-body').value}).catch(()=>{});
document.getElementById('complete-onboarding').onclick=()=>command('onboarding.complete').catch(()=>{});
reconnect();
</script></body></html>
"""#
}
