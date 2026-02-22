#!/usr/bin/env python3
import socket

PORT = 4747
SERVER = socket.gethostbyname(socket.gethostname())

addr = (SERVER, PORT)

with socket.socket(family=socket.AF_INET, type=socket.SOCK_STREAM) as s:

    s.bind(addr)
    s.listen()
    print(f"Listening on {SERVER}:{PORT}")
    c, a = s.accept()
    print(f"Client connected from {a}")
    with c:
        m = c.recv(1024)
        print(m.decode())
        c.sendall(b"Hello back!")


