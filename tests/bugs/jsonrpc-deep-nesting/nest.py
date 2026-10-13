# Send one HTTP POST whose body is a JSON array nested `depth` levels deep
# ("[[[...]]]") to the JSON-RPC server, and report how many response bytes
# came back. Run with: python3 -I nest.py <host> <port> <depth>
import socket, sys

host = sys.argv[1]
port = int(sys.argv[2])
depth = int(sys.argv[3])
body = (b"[" * depth) + (b"]" * depth)
hdr = ("POST / HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n"
       "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)).encode()
try:
    s = socket.create_connection((host, port), timeout=15)
    s.sendall(hdr + body)
    got = 0
    while True:
        c = s.recv(65536)
        if not c:
            break
        got += len(c)
    s.close()
    print("depth=%d bodybytes=%d responsebytes=%d" % (depth, len(body), got))
except Exception as e:
    print("depth=%d bodybytes=%d connerror=%r" % (depth, len(body), e))
