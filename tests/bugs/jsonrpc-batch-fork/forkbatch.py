# Send ONE JSON-RPC batch of `n` "fork" entries on a single connection and print how
# many response objects the parent returned (and the child server addresses it reports).
# Run with: python3 -I forkbatch.py <host> <port> <n>
import socket, sys, json

host = sys.argv[1]
port = int(sys.argv[2])
n = int(sys.argv[3])
batch = [{"jsonrpc": "2.0", "id": i, "method": "fork"} for i in range(n)]
body = json.dumps(batch).encode()
hdr = ("POST / HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n"
       "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)).encode()
s = socket.create_connection((host, port), timeout=15)
s.sendall(hdr + body)
d = b""
try:
    while True:
        c = s.recv(65536)
        if not c:
            break
        d += c
except Exception:
    pass
s.close()
payload = d.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in d else d
try:
    arr = json.loads(payload)
    addrs = [r.get("result", {}).get("address") for r in arr
             if isinstance(r, dict) and "result" in r]
    print("batch of %d forks -> %d response object(s); child addresses: %r" % (n, len(arr), addrs))
except Exception as e:
    print("parse error: %r %r" % (e, payload[:200]))
