import Foundation

// 注入 WKWebView 页面的三段 JS（内联为 Swift 字符串，零资源文件依赖）。
//
// - bgutilsBundle: LuanRT/BgUtils (bgutils-js 4.0.3, MIT) 的 esbuild IIFE 打包，
//   提供 BotGuardClient / WebPoMinter / buildURL / getHeaders / parseLooseJSON。
// - stage1: 在真实 youtube.com 页面里收 visitorData 与 ytAtN 内嵌 BotGuard 挑战。
// - stage2: 传入宿主下载好的 interpreter JS，跑快照 → GenerateIT → 铸 POT。
//
// 注意：callAsyncJavaScript 的 arguments 按 key 直接注入脚本作用域
//（用 `program` 而非 `args.program`）。
enum WebPoTokenScripts {
    /// BotGuard 互操作库（bgutils-js 4.0.3，MIT，esbuild 打包）、
    static let bgutilsBundle = #"""
var __BgUtils=(()=>{var w=Object.defineProperty;var O=Object.getOwnPropertyDescriptor;var C=Object.getOwnPropertyNames;var _=Object.prototype.hasOwnProperty;var A=(o,t)=>{for(var e in t)w(o,e,{get:t[e],enumerable:!0})},M=(o,t,e,n)=>{if(t&&typeof t=="object"||typeof t=="function")for(let r of C(t))!_.call(o,r)&&r!==e&&w(o,r,{get:()=>t[r],enumerable:!(n=O(t,r))||n.enumerable});return o};var U=o=>M(w({},"__esModule",{value:!0}),o);var z={};A(z,{BotGuardClient:()=>p,WebPoMinter:()=>f,buildURL:()=>k,getHeaders:()=>E,parseLooseJSON:()=>F});var g="https://jnn-pa.googleapis.com",y="https://www.youtube.com",x="AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw",S="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36(KHTML, like Gecko)";var b=/[-_.]/g,P={"-":"+",_:"/",".":"="},d=class{promise;resolve;reject;constructor(){this.promise=new Promise((t,e)=>{this.resolve=t,this.reject=e})}},s=class extends TypeError{info;constructor(t,e){super(t),this.name="BgError",e&&(this.info=e)}};function v(o){let t;return b.test(o)?t=o.replace(b,function(e){return P[e]}):t=o,t=atob(t),new Uint8Array([...t].map(e=>e.charCodeAt(0)))}function T(o,t=!1){let e=btoa(String.fromCharCode(...o));return t?e.replace(/\+/g,"-").replace(/\//g,"_"):e}function F(o){let e=o.replace(/\\x([0-9A-Fa-f]{2})/g,(r,i)=>String.fromCharCode(parseInt(i,16))).replace(/,\s*([\]}])/g,"$1");e=e.replace(/'((?:[^'\\]|\\[\s\S])*)'/g,(r,i)=>{let c=i.replace(/\\'/g,"'");return JSON.stringify(c)}),e=e.replace(/([{,]\s*)([a-zA-Z0-9_$]+)\s*:/g,'$1"$2":');let n=JSON.parse(e);for(let r in n){let i=n[r];if(typeof i=="string"&&(i.trim().startsWith("{")||i.trim().startsWith("[")))try{n[r]=JSON.parse(i)}catch{}}return n}function G(){let o=typeof window<"u"&&typeof window.document<"u"&&typeof window.document.createElement<"u"&&typeof window.HTMLElement<"u"&&typeof window.navigator<"u"&&typeof window.getComputedStyle=="function"&&typeof window.requestAnimationFrame=="function"&&typeof window.matchMedia=="function",t=Object.getOwnPropertyDescriptor(globalThis,"window")?.get?.toString().includes("[native code]")??!1;return o&&t}function E(){let o={"content-type":"application/json+protobuf","x-goog-api-key":x,"x-user-agent":"grpc-web-javascript/0.1"};return G()||(o["user-agent"]=S),o}function k(o,t){return`${t?y:g}/${t?"api/jnn/v1":"$rpc/google.internal.waa.v1.Waa"}/${o}`}var h=class{#t=new Map;#e=new Map;emit(t,...e){let n=this.#t.get(t);if(!(!n||n.size===0))for(let r of[...n])r(...e)}on(t,e){let n=this.#t.get(t);n||(n=new Set,this.#t.set(t,n)),n.add(e)}once(t,e){let n=(...i)=>{this.off(t,e),e(...i)},r=this.#e.get(e);r||(r=new Map,this.#e.set(e,r)),r.set(t,n),this.on(t,n)}off(t,e){let n=this.#t.get(t);if(!n)return;let r=e,i=this.#e.get(e);if(i){let c=i.get(t);c&&(r=c,i.delete(t),i.size===0&&this.#e.delete(e))}n.delete(r),n.size===0&&this.#t.delete(t)}removeAllListeners(t){if(!t){this.#t.clear(),this.#e.clear();return}this.#t.delete(t);for(let[e,n]of this.#e.entries())n.delete(t),n.size===0&&this.#e.delete(e)}};var p=class o extends h{vm;program;userInteractionElement;syncSnapshotFunction;deferredVmFunctions=new d;defaultTimeout=3e3;on(t,e){super.on(t,e)}off(t,e){super.off(t,e)}constructor(t){if(super(),!t.globalObject||!t.globalName||!t.program)throw new s("Invalid options",{options:t});this.userInteractionElement=t.userInteractionElement,this.vm=t.globalObject[t.globalName],this.program=t.program}static async create(t){return await new o(t).load()}async load(){if(!this.vm)throw new s("EGOU: BotGuard unavailable");if(!this.vm.a)throw new s("ELIU: BotGuard initialization function unavailable");let t=(a,l,m,u)=>{this.deferredVmFunctions.resolve({asyncSnapshotFunction:a,shutdownFunction:l,passEventFunction:m,checkCameraFunction:u})},e=(a,l)=>{this.emit("record-bg-event",{event:a,elapsedTime:l})},n=a=>{this.emit("increment-client-error-count",{errorCode:a})},r=a=>{this.emit("record-payload-size",{payloadSize:a})},i=(a,l)=>{this.emit("record-latency",{latency:a,et:l})},c=a=>{this.emit("increment-bg-event-count",{event:a})},B=[e,n,r,i,c],L=(a,l,m)=>{let u="k";l?u="h":m&&(u="u"),c(u),e(u,a)};try{this.syncSnapshotFunction=await this.vm.a(this.program,t,!0,this.userInteractionElement,L,[[],[]],void 0,!1,B)?.[0]}catch(a){throw new s("Could not load program",{error:a})}return this}async execute(t,e,...n){return await Promise.race([(async()=>{let i=(await this.deferredVmFunctions.promise)[t];if(!i)throw new s(`${t} function not found`);return i(...n)})(),new Promise((r,i)=>setTimeout(()=>i(new s("VM operation timed out")),e))])}async snapshot(t,e=this.defaultTimeout){return await new Promise(async(n,r)=>{await this.execute("asyncSnapshotFunction",e,i=>n(i),[t.contentBinding,t.signedTimestamp,t.webPoSignalOutput,t.skipPrivacyBuffer]).catch(r)})}async passEvent(t,e=this.defaultTimeout){return this.execute("passEventFunction",e,t)}async checkCamera(t,e=this.defaultTimeout){return this.execute("checkCameraFunction",e,t)}async shutdown(t=this.defaultTimeout){return this.execute("shutdownFunction",t)}async snapshotSynchronous(t){if(!this.syncSnapshotFunction)throw new s("Synchronous snapshot function not found");return this.syncSnapshotFunction([t.contentBinding,t.signedTimestamp,t.webPoSignalOutput,t.skipPrivacyBuffer])}};var f=class o{mintCallback;constructor(t){this.mintCallback=t}static async create(t,e){let n=e[0];if(!n)throw new s("PMD:Undefined");if(!t.integrityToken)throw new s("No integrity token provided",{integrityTokenResponse:t});let r=await n(v(t.integrityToken));if(!(r instanceof Function))throw new s("APF:Failed");return new o(r)}async mintAsWebsafeString(t){return T(await this.mint(t),!0)}async mint(t){let e=await this.mintCallback(new TextEncoder().encode(t));if(!e)throw new s("YNJ:Undefined");if(!(e instanceof Uint8Array))throw new s("ODM:Invalid");return e}};return U(z);})();
"""#

    /// 第一段：visitorData + ytAtN 挑战（页面内执行）
    static let stage1 = #"""
// 第一段（页面内）：visitorData + ytAtN 挑战元数据 → 返回给 Swift
const out = {};
try {
  const visitorData = window.ytcfg && ytcfg.get('VISITOR_DATA');
  if (!visitorData) throw new Error('no VISITOR_DATA in ytcfg');
  out.visitorData = visitorData;
  const dataSyncID = ytcfg.get('DATASYNC_ID') || '';
  out.dataSyncID = dataSyncID;
  out.gvsBoundToVideo = Object.values(ytcfg.get('WEB_PLAYER_CONTEXT_CONFIGS') || {}).some(c =>
    new URLSearchParams(c.serializedExperimentFlags || '').get('html5_generate_content_po_token') === 'true');

  const pageResp = await fetch('/', { credentials: 'include', signal: AbortSignal.timeout(15000) });
  const html = await pageResp.text();
  const configMatch = html.match(/ytcfg\.set\(({[\s\S]*?})\);/);
  if (!configMatch) throw new Error('no attestation ytcfg in homepage html');
  const attestationConfig = __BgUtils.parseLooseJSON(configMatch[1]);
  if (!attestationConfig || !attestationConfig.EVENT_ID) throw new Error('no attestation EVENT_ID');
  out.attestationConfig = attestationConfig;
  const m = html.match(/window\.ytAtN\(\s*({[\s\S]*?})\s*\)/);
  if (!m) throw new Error('no ytAtN challenge in homepage html');
  const att = __BgUtils.parseLooseJSON(m[1]);
  const ch = att && att.R && att.R.bgChallenge;
  if (!ch || !ch.program || !ch.globalName) throw new Error('bad bgChallenge');
  out.program = ch.program;
  out.globalName = ch.globalName;
  out.interpreterUrl = (ch.interpreterUrl && ch.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue) || null;
  out.interpreterJS = (ch.interpreterJavascript && ch.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue) || null;
  out.ok = true;
} catch (e) {
  out.ok = false;
  out.error = String((e && e.message) || e);
}
return JSON.stringify(out);
"""#

    /// 第二段：interpreter（宿主下载）→ BotGuard → GenerateIT → POT
    // DATASYNC_ID is the full account binding, including the delegated channel separator.
    static let sessionBinding = #"""
(authenticated, dataSyncID, visitorData) => {
  if (authenticated) {
    if (!dataSyncID) throw new Error('Authenticated GVS requires DATASYNC_ID');
    return dataSyncID;
  }
  if (!visitorData) throw new Error('Anonymous GVS requires visitorData');
  return visitorData;
}
"""#
    /// BotGuard reads yt.config_.EVENT_ID; it must belong to the challenge's response.
    /// Restore the watch-page environment after minting, including failure paths.
    static let attestationEnvironment = #"""
(config) => {
  if (!config || !config.EVENT_ID) throw new Error('Missing challenge-matched EVENT_ID');
  const hadYT = Object.prototype.hasOwnProperty.call(window, 'yt');
  const previousYT = window.yt;
  const yt = window.yt || (window.yt = {});
  const hadConfig = Object.prototype.hasOwnProperty.call(yt, 'config_');
  const previousConfig = yt.config_;
  yt.config_ = config;
  return () => {
    if (hadConfig) yt.config_ = previousConfig;
    else delete yt.config_;
    if (hadYT) window.yt = previousYT;
    else delete window.yt;
  };
}
"""#
    static let stage2 = "const resolveSessionBinding = " + sessionBinding + ";\n"
        + "const installAttestationEnvironment = " + attestationEnvironment + ";\n" + #"""
// 第二段（页面内）：宿主已下载 interpreter JS，传入后 eval → BotGuard → GenerateIT → 铸 POT
// 注意：callAsyncJavaScript 的 arguments 按 key 直接注入作用域。
const out = {};
let restoreEnvironment;
try {
  restoreEnvironment = installAttestationEnvironment(attestationConfig);
  if (!interpreterJS) throw new Error('no interpreterJS provided');
  let evaled = false;
  out.hasTrustedTypes = typeof trustedTypes !== 'undefined';
  if (out.hasTrustedTypes) {
    try {
      const p = trustedTypes.createPolicy('potprobe', { createScript: (s) => s, createScriptURL: (u) => u });
      new Function(p.createScript(interpreterJS))();
      evaled = true;
      out.evalVia = 'policy';
    } catch (e) {
      out.ttPolicyError = String((e && e.message) || e);
    }
  }
  if (!evaled) {
    new Function(interpreterJS)();
    out.evalVia = 'direct';
  }
  const vmObj = window[globalName];
  if (!vmObj) throw new Error('VM global missing: ' + globalName);
  out.vmLoaded = true;

  const bg = await __BgUtils.BotGuardClient.create({
    program: program, globalName: globalName, globalObject: window,
  });
  const signals = [];
  const response = await bg.snapshot({ webPoSignalOutput: signals });
  out.bgResponseLen = response ? String(response).length : 0;

  const itResp = await fetch(__BgUtils.buildURL('GenerateIT'), {
    method: 'POST',
    signal: AbortSignal.timeout(20000),
    headers: __BgUtils.getHeaders(),
    body: JSON.stringify(['O43z0dpjhgX20SCx4KAo', response]),
  });
  out.itStatus = itResp.status;
  const itData = await itResp.json();
  const integrityToken = Array.isArray(itData) ? itData[0] : itData.integrityToken;
  const ttlSecs = Array.isArray(itData) ? itData[1] : itData.estimatedTtlSecs;
  if (!integrityToken) {
    out.itRaw = JSON.stringify(itData).slice(0, 300);
    throw new Error('no integrity token');
  }
  out.itTtlSecs = ttlSecs;

  const minter = await __BgUtils.WebPoMinter.create(
    { integrityToken, estimatedTtlSecs: ttlSecs }, signals);
  out.sessionPoToken = await minter.mintAsWebsafeString(resolveSessionBinding(authenticated, dataSyncID, visitorData));
  out.poToken = out.sessionPoToken;
  if (videoID) out.videoPoToken = await minter.mintAsWebsafeString(videoID);
  await bg.shutdown();
  out.ok = true;
} catch (e) {
  out.ok = false;
  out.error = String((e && e.message) || e);
} finally {
  if (restoreEnvironment) restoreEnvironment();
}
return JSON.stringify(out);
"""#
    /// Experimental WPC path, following coletdjnz/yt-dlp-getpot-wpc (MIT).
    /// No fallback/error/cold-start tokens are requested. Missing native API is an error.
    static let nativeWebPoClient = "const resolveSessionBinding = " + sessionBinding + ";\n" + #"""
const out = {};
try {
  const visitorData = ytcfg.get('VISITOR_DATA');
  const dataSyncID = ytcfg.get('DATASYNC_ID') || '';
  let owner;
  for (let i = 0; i < 10; i++) {
    owner = window.top['havuokmhhs-0']?.bevasrs;
    if (typeof owner?.wpc === 'function') break;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  if (typeof owner?.wpc !== 'function') throw new Error('Native WebPoClient unavailable');
  async function mint(binding) {
    for (let i = 0; i < 10; i++) {
      try {
        let timer;
        let value;
        try {
          value = await Promise.race([
            owner.wpc().then(client => client.mws({c: binding, mc: false, me: false})),
            new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Native WebPoClient timed out')), 15000); })
          ]);
        } finally {
          clearTimeout(timer);
        }
        if (typeof value !== 'string' || !value) throw new Error('Empty native PO Token');
        return value;
      } catch (e) {
        if (!String(e).includes('SDF:notready')) throw e;
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    }
    throw new Error('Native WebPoClient not ready');
  }
  out.visitorData = visitorData;
  out.sessionPoToken = await mint(resolveSessionBinding(authenticated, dataSyncID, visitorData));
  if (videoID) out.videoPoToken = await mint(videoID);
  out.gvsBoundToVideo = Object.values(ytcfg.get('WEB_PLAYER_CONTEXT_CONFIGS') || {}).some(c =>
    new URLSearchParams(c.serializedExperimentFlags || '').get('html5_generate_content_po_token') === 'true');
  out.ok = true;
} catch (e) {
  out.ok = false;
  out.error = String((e && e.message) || e);
}
return JSON.stringify(out);
"""#

}
