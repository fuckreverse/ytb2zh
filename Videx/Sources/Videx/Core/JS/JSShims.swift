import Foundation

/// 挑战代码运行前的全局环境垫片。
///
/// YouTube player JS 的挑战函数体相对自包含，但偶尔引用浏览器全局
/// 对象（console / window / document / navigator / atob 等）。
/// 这些垫片足够让常见变体跑通；遇到新引用时在此追加。
public enum JSShims {
    /// 键仅为排序稳定性服务；值为直接可 evaluate 的 JS 语句。
    public static let browserStubs: [String: String] = [
        "window": "var window = this; var self = this; var globalThis = this;",
        "console": """
        var console = {
          log: function(){}, info: function(){}, warn: function(){},
          error: function(){}, debug: function(){}, trace: function(){},
          table: function(){}, dir: function(){}, group: function(){},
          groupEnd: function(){}, time: function(){}, timeEnd: function(){},
          count: function(){}, assert: function(){}
        };
        """,
        "document": """
        var document = {
          createElement: function(){ return { style: {}, setAttribute: function(){}, appendChild: function(){}, getElementsByTagName: function(){ return [] } }; },
          getElementsByTagName: function(){ return []; },
          getElementById: function(){ return null; },
          createTextNode: function(){ return {}; },
          documentElement: {}, head: {}, body: {},
          cookie: "",
          location: { href: "https://www.youtube.com/", protocol: "https:", host: "www.youtube.com" }
        };
        """,
        "navigator": """
        var navigator = {
          userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
          language: "en-US", languages: ["en-US"], platform: "MacIntel"
        };
        """,
        "performance": "var performance = { now: function(){ return Date.now(); }, timing: {} };",
        "location": """
        var location = { hash: "", host: "www.youtube.com", hostname: "www.youtube.com",
          href: "https://www.youtube.com/", origin: "https://www.youtube.com",
          pathname: "/", port: "", protocol: "https:", search: "", assign: function(){},
          replace: function(){}, reload: function(){}, toString: function(){ return this.href; } };
        """,
        "atob": """
        var atob = function(s) {
          var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
          s = String(s).replace(/[=]+$/, "");
          var out = "", bits = 0, acc = 0;
          for (var i = 0; i < s.length; i++) {
            acc = (acc << 6) + chars.indexOf(s.charAt(i));
            bits += 6;
            if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 0xff); }
          }
          return out;
        };
        """,
        "btoa": """
        var btoa = function(s) {
          var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
          var out = "";
          for (var i = 0; i < s.length; i += 3) {
            var b = [s.charCodeAt(i), s.charCodeAt(i+1), s.charCodeAt(i+2)];
            out += chars.charAt(b[0] >> 2)
                 + chars.charAt(((b[0] & 3) << 4) | (isNaN(b[1]) ? 0 : (b[1] >> 4)))
                 + (isNaN(b[1]) ? "=" : chars.charAt(((b[1] & 15) << 2) | (isNaN(b[2]) ? 0 : (b[2] >> 6))))
                 + (isNaN(b[2]) ? "=" : chars.charAt(b[2] & 63));
          }
          return out;
        };
        """,
    ]
}
