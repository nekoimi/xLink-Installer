"""Real container communication tests; all resources use disposable unique names."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


MARKER = "xlink-communication-ok"
BACKEND = '''from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl
import threading
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"xlink-communication-ok")
    def log_message(self, *args):
        pass
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_3
context.set_alpn_protocols(["h2", "http/1.1"])
context.load_cert_chain("/fixtures/target.crt", "/fixtures/target.key")
target = ThreadingHTTPServer(("0.0.0.0", 10443), Handler)
target.socket = context.wrap_socket(target.socket, server_side=True)
threading.Thread(target=target.serve_forever, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 18080), Handler).serve_forever()
'''


def client_config(identity, server="127.0.0.1", backend="backend"):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"listen": "127.0.0.1", "port": 19080, "protocol": "dokodemo-door",
                      "settings": {"address": backend, "port": 18080, "network": "tcp"}}],
        "outbounds": [{
            "protocol": "vless",
            "settings": {"vnext": [{"address": server, "port": 8443,
                                     "users": [{"id": identity["uuid"], "encryption": "none",
                                                "flow": "xtls-rprx-vision"}]}]},
            "streamSettings": {
                "network": "raw", "security": "reality",
                "realitySettings": {"serverName": "reality.example.com", "fingerprint": "chrome",
                                    "password": identity["reality_public_key"],
                                    "shortId": identity["short_id"]},
            },
        }],
    }


def docker(*args, check=True):
    return subprocess.run(["docker", *args], check=check, text=True, capture_output=True, timeout=60)


def wait_for(check, label, attempts=40):
    for _ in range(attempts):
        if check():
            return
        time.sleep(0.5)
    raise RuntimeError(f"Timed out waiting for {label}")


def main(image):
    prefix = "xlink-smoke-" + uuid.uuid4().hex[:10]
    network, volume = prefix + "-net", prefix + "-data"
    server, backend, tunnel = prefix + "-server", prefix + "-backend", prefix + "-tunnel"
    containers = [server, backend, tunnel]
    with tempfile.TemporaryDirectory() as directory:
        files = Path(directory)
        (files / "backend.py").write_text(BACKEND, encoding="utf-8")
        # Test-only TLS target; OpenSSL runs on the CI host, not in the image.
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=reality.example.com", "-addext", "subjectAltName=DNS:reality.example.com",
                        "-keyout", str(files / "target.key"), "-out", str(files / "target.crt")],
                       check=True, capture_output=True, timeout=30)
        try:
            docker("network", "create", network)
            docker("volume", "create", volume)
            docker("run", "-d", "--name", backend, "--network", network,
                   "--network-alias", "backend", "--network-alias", "backend.test", "--entrypoint", "python3",
                   "--mount", f"type=bind,src={files},dst=/fixtures,readonly",
                   image, "/fixtures/backend.py")
            docker("create", "--name", server, "--network", network,
                   "--network-alias", "xlink.test", "--cap-drop", "ALL",
                   "--cap-add", "NET_BIND_SERVICE", "--security-opt", "no-new-privileges:true",
                   "-e", "PUBLIC_HOST=xlink.test", "-e", "REALITY_SERVER_NAME=reality.example.com",
                   "-e", "REALITY_TARGET=backend.test:10443",
                   "--mount", f"type=volume,src={volume},dst=/data", image)
            docker("start", server)

            def healthy():
                return docker("exec", server, "python3", "/opt/xlink/app.py", "healthcheck",
                              check=False).returncode == 0

            def read_identity():
                docker("cp", f"{server}:/data/identity.json", str(files / "identity.json"))
                return json.loads((files / "identity.json").read_text())

            def fetch(port):
                result = docker("exec", server, "python3", "-c",
                                "import urllib.request; "
                                f"print(urllib.request.urlopen('http://127.0.0.1:{port}', timeout=3).read().decode())",
                                check=False)
                return result.returncode == 0 and MARKER in result.stdout

            wait_for(healthy, "server ports (without a tunnel client)")
            identity = read_identity()

            (files / "client.json").write_text(json.dumps(client_config(identity)), encoding="utf-8")
            docker("cp", str(files / "client.json"), f"{server}:/data/test-client.json")
            docker("exec", "-d", server, "xray", "run", "-config", "/data/test-client.json")
            wait_for(lambda: fetch(19080), "VLESS REALITY + Vision communication")
            print("VLESS REALITY + Vision OK", flush=True)

            docker("cp", f"{server}:/data/rathole/client.toml", str(files / "client.toml"))
            client = (files / "client.toml").read_text().replace("127.0.0.1:443", "backend:18080")
            (files / "client.toml").write_text(client, encoding="utf-8")
            docker("run", "-d", "--name", tunnel, "--network", network, "--entrypoint", "rathole",
                   "--mount", f"type=bind,src={files},dst=/fixtures,readonly",
                   image, "--client", "/fixtures/client.toml")
            wait_for(lambda: fetch(443), "Noise tunnel forwarding")
            print("rathole Noise forwarding OK", flush=True)

            docker("stop", "--time", "15", server)
            state = json.loads(docker("inspect", "--format", "{{json .State}}", server).stdout)
            if state["ExitCode"] != 0:
                raise RuntimeError("SIGTERM shutdown did not exit cleanly")
            docker("start", server)
            wait_for(healthy, "restart")
            if read_identity() != identity:
                raise RuntimeError("Restart changed persistent identities")
            wait_for(lambda: fetch(443), "tunnel reconnect")
            print("Clean shutdown, stable identities and tunnel reconnect OK", flush=True)

            docker("exec", server, "python3", "-c", r'''import os, signal
from pathlib import Path
for path in Path('/proc').glob('[0-9]*/cmdline'):
    try:
        command = path.read_bytes()
        if command.startswith(b'xray\0run\0-config\0/data/xray.json\0'):
            os.kill(int(path.parent.name), signal.SIGTERM)
            break
    except (FileNotFoundError, ProcessLookupError):
        continue
else:
    raise RuntimeError('Xray process not found')
''')
            wait_for(lambda: docker("inspect", "--format", "{{.State.Running}}", server).stdout.strip() == "false",
                     "container exit after service failure")
            if docker("inspect", "--format", "{{.State.ExitCode}}", server).stdout.strip() != "1":
                raise RuntimeError("Service failure did not produce a failing container exit code")
            print("Service failure supervision OK", flush=True)
        except BaseException:
            for name in containers:
                logs = docker("logs", "--tail", "60", name, check=False)
                print(f"{name}:\n{logs.stdout}{logs.stderr}", file=sys.stderr)
            raise
        finally:
            for name in containers:
                docker("rm", "-f", name, check=False)
            docker("volume", "rm", volume, check=False)
            docker("network", "rm", network, check=False)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "xlink:smoke")
