# Dev server that tells the browser never to cache (the plain http.server lets it keep a stale game.wasm):
#   python3 tools/serve.py [port] [dir]     (defaults: 8000, build/web)
import http.server, sys, functools

class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
root = sys.argv[2] if len(sys.argv) > 2 else "build/web"
handler = functools.partial(NoCache, directory=root)
http.server.ThreadingHTTPServer(("", port), handler).serve_forever()
