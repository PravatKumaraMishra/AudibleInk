import SwiftUI
import WebKit

struct MarkdownPreview: NSViewRepresentable {
    @ObservedObject var reader: Reader
    func makeCoordinator() -> Coordinator { Coordinator(reader) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "reader")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.html != reader.previewHTML {
            coordinator.html = reader.previewHTML
            view.loadHTMLString(Self.page(reader.previewHTML), baseURL: nil)
        } else {
            coordinator.highlight(view)
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let reader: Reader
        var html: String?
        init(_ reader: Reader) { self.reader = reader }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let index = body["index"] as? Int { reader.start(at: index) }
            if body["manualScroll"] as? Bool == true { reader.followReading = false }
        }
        func highlight(_ view: WKWebView) {
            let index = reader.active ? reader.current : -1
            view.evaluateJavaScript("window.markPassage && window.markPassage(\(index), \(reader.followReading ? "true" : "false"))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { highlight(webView) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
    static func page(_ body: String) -> String {
        return #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; connect-src 'none'">
        <style>
        :root { color-scheme: light; } * { box-sizing: border-box; }
        body { margin: 0; padding: 18px 22px 40px; color: #293b35; background: #fffefa; font: 16px/1.8 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
        h1,h2,h3,h4,h5,h6 { line-height:1.35; margin: 1.5em 0 .6em; color:#203a30; }
        h1 { font: 600 32px/1.3 Georgia,serif; border-bottom:1px solid #e5e8de; padding-bottom:16px; margin-top:0; }
        h2 { font: 600 25px/1.4 Georgia,serif; border-bottom:1px solid #e5e8de; padding-bottom:8px; }
        h3 { font-size:20px; } p { margin: .8em 0; } li { margin:.35em 0; }
        code { font: .86em/1.7 ui-monospace,monospace; background:#edf0e8; border-radius:4px; padding:2px 5px; }
        pre { background:#f0f2ec; border:1px solid #dfe5d8; padding:18px; overflow:auto; border-radius:9px; white-space:pre; }
        pre code { padding:0; background:none; } blockquote { margin:20px 0; padding:4px 20px; border-left:3px solid #93ab94; color:#576a60; background:#f5f6ef; }
        table { border-collapse:collapse; width:100%; margin:20px 0; font-size:14px; } th,td { border:1px solid #dce3d6; padding:10px 13px; text-align:left; } th { background:#edf1e7; }
        hr { border:0; border-top:1px solid #dfe5d8; margin:30px 0; } a { color:#40764f; text-decoration:underline; }
        .passage { border-radius:3px; cursor:pointer; transition:background .15s; box-decoration-break:clone; -webkit-box-decoration-break:clone; }
        .passage:hover { background:#e9eee1; } .passage.current { background:#e0ebc6; box-shadow:0 2px 0 #a0b87e; }
        ::selection { background:#cddfb6; } .hint { font-size:12px; color:#6e7e70; padding-bottom:16px; border-bottom:1px solid #e5e8de; margin-bottom:24px; }
        #selectionPlay { display:none; position:fixed; bottom:18px; right:20px; border:0; border-radius:20px; padding:12px 18px; color:white; background:#293b35; box-shadow:0 3px 15px #0002; cursor:pointer; }
        </style></head><body>
        <main>
        """# + body + #"""
        </main><button id="selectionPlay">▶ Read from selection</button>
        <script>
        let current = -2, following = false, selectionIndex = null;
        const send = body => window.webkit.messageHandlers.reader.postMessage(body);
        window.markPassage = (index, follow) => {
          const changed = index !== current, resumed = follow && !following;
          if(changed) {
            document.querySelectorAll('.current').forEach(n => n.classList.remove('current'));
            document.querySelectorAll('[data-chunk="'+index+'"]').forEach(n => n.classList.add('current'));
            current = index;
          }
          if(follow && (changed || resumed)) document.querySelector('.current')?.scrollIntoView({behavior:'smooth',block:'center'});
          following = follow;
        };
        document.addEventListener('click', e => {
          if(e.target.closest('#selectionPlay')) {
            if(selectionIndex !== null) { send({index:selectionIndex}); getSelection().removeAllRanges(); }
            return;
          }
          if(!getSelection().isCollapsed) return;
          const passage = e.target.closest('[data-chunk]');
          if(passage) { e.preventDefault(); send({index:Number(passage.dataset.chunk)}); }
          else if(e.target.closest('a')) e.preventDefault();
        });
        document.addEventListener('selectionchange', () => {
          const s = getSelection(), button = document.getElementById('selectionPlay');
          selectionIndex = null;
          if(s && !s.isCollapsed && s.rangeCount) {
            let node = s.getRangeAt(0).startContainer;
            let el = node.nodeType === 1 ? node : node.parentElement;
            let passage = el.closest('[data-chunk]');
            if(!passage) {
              const range = s.getRangeAt(0);
              passage = [...document.querySelectorAll('[data-chunk]')].find(n => range.intersectsNode(n));
            }
            if(passage) selectionIndex = Number(passage.dataset.chunk);
          }
          button.style.display = selectionIndex === null ? 'none' : 'block';
        });
        document.getElementById('selectionPlay').addEventListener('mousedown', e => e.preventDefault());
        document.addEventListener('wheel', () => { if(following) { following=false; send({manualScroll:true}); } }, {passive:true});
        document.addEventListener('keydown', e => { if(['PageDown','PageUp','ArrowDown','ArrowUp','Home','End'].includes(e.key)) { following=false; send({manualScroll:true}); } });
        </script></body></html>
        """#
    }
}
