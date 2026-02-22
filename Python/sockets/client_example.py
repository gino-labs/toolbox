#!/usr/bin/env python3
import socket

SERVER = socket.gethostbyname('ryzenbolt')
PORT = 4747
addr = (SERVER, PORT)

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    bmsg = b"Hello World!"
    s.connect(addr)
    s.sendall(bmsg)
    m = s.recv(1024)
    print(m.decode())
