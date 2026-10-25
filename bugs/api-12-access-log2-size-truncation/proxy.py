# Minimal JSON-RPC HTTP proxy: forwards to a real cartesi-jsonrpc-machine and
# tampers with machine.get_proof responses according to MODE.
import sys, json, http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
listen_port, upstream_port, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        req = json.loads(body)
        c = http.client.HTTPConnection("127.0.0.1", upstream_port, timeout=30)
        c.request("POST", self.path, body, {"Content-Type": "application/json"})
        r = c.getresponse(); data = r.read(); c.close()
        if req.get("method") == "machine.get_proof":
            resp = json.loads(data)
            res = resp.get("result")
            if isinstance(res, dict):
                if mode == "target":
                    res["log2_target_size"] += 1 << 32
                elif mode == "root":
                    res["log2_root_size"] += 1 << 32
            data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
ThreadingHTTPServer(("127.0.0.1", listen_port), H).serve_forever()
