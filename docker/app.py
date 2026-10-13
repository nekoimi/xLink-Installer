"""Initialize persistent identities and supervise Xray and rathole."""

import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode, urlsplit
import uuid


DATA = Path("/data")


def host(value, name, domain_only=False):
    try:
        address = ipaddress.ip_address(value)
        if not domain_only:
            return str(address)
    except ValueError:
        pass
    if (len(value) > 253 or "." not in value or
            not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                    for label in value.split("."))):
        raise ValueError(f"{name} must be a valid {'domain' if domain_only else 'IP or domain'}")
    if domain_only:
        try:
            ipaddress.ip_address(value)
        except ValueError:
            return value.lower()
        raise ValueError(f"{name} must be a domain, not an IP")
    return value.lower()


def endpoint(value, name):
    # URI brackets also work for IPv6 socket addresses in Xray and rathole.
    parsed = urlsplit("//" + value)
    if (not parsed.hostname or parsed.username is not None or parsed.password is not None
            or parsed.path or parsed.query or parsed.fragment or not parsed.port):
        raise ValueError(f"{name} must be host:port (bracket IPv6 addresses)")
    host(parsed.hostname, name)
    return value


def settings(env):
    result = {
        "public_host": host(env.get("PUBLIC_HOST", ""), "PUBLIC_HOST"),
        "server_name": host(env.get("REALITY_SERVER_NAME", "www.microsoft.com"),
                            "REALITY_SERVER_NAME", domain_only=True),
        "xray_port": int(env.get("XRAY_PORT", "8443")),
        "rathole_port": int(env.get("RATHOLE_PORT", "2333")),
    }
    result["target"] = endpoint(env.get("REALITY_TARGET") or result["server_name"] + ":443",
                                "REALITY_TARGET")
    ports = [443, result["xray_port"], result["rathole_port"]]
    if len(set(ports)) != len(ports) or any(not 1 <= port <= 65535 for port in ports):
        raise ValueError("XRAY_PORT/RATHOLE_PORT must be distinct ports, excluding 443")
    return result


def write(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     delete=False, newline="\n") as output:
        temp = Path(output.name)
        try:
            os.chmod(temp, 0o600)
            output.write(contents)
        except BaseException:
            temp.unlink(missing_ok=True)
            raise
    os.replace(temp, path)


def command_output(args):
    completed = subprocess.run(args, capture_output=True, text=True, check=True, timeout=30)
    return completed.stdout + completed.stderr


def identities(data, runner=command_output):
    path = data / "identity.json"
    if path.exists():
        identity = json.loads(path.read_text(encoding="utf-8"))
    else:
        xray = runner(["xray", "x25519"])
        noise = runner(["rathole", "--genkey"])
        private = re.search(r"^PrivateKey:\s*(\S+)", xray, re.M)
        public = re.search(r"^Password \(PublicKey\):\s*(\S+)", xray, re.M)
        pair = re.search(r"Private Key:\s*([A-Za-z0-9+/=]+)\s+Public Key:\s*([A-Za-z0-9+/=]+)", noise)
        if not (private and public and pair):
            raise ValueError("Unexpected Xray/rathole key output; identities were not saved")
        identity = {
            "uuid": str(uuid.uuid4()),
            "reality_private_key": private[1],
            "reality_public_key": public[1],
            "short_id": secrets.token_hex(8),
            "noise_private_key": pair[1],
            "noise_public_key": pair[2],
            "rathole_token": secrets.token_hex(32),
        }
    uuid.UUID(identity["uuid"])
    for name in ("reality_private_key", "reality_public_key"):
        value = identity[name]
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", value):
            raise ValueError(f"Invalid saved {name}; refusing to rotate identities")
        if len(base64.urlsafe_b64decode(value + "=")) != 32:
            raise ValueError(f"Invalid saved {name}")
    for name in ("noise_private_key", "noise_public_key"):
        if len(base64.b64decode(identity[name], validate=True)) != 32:
            raise ValueError(f"Invalid saved {name}")
    for name, length in (("short_id", 16), ("rathole_token", 64)):
        if not re.fullmatch(r"[0-9a-f]{%d}" % length, identity[name]):
            raise ValueError(f"Invalid saved {name}")
    write(path, json.dumps(identity, indent=2) + "\n")
    return identity


def authority(hostname):
    return f"[{hostname}]" if ":" in hostname else hostname


def render(data, config, identity):
    xray = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "vless-reality", "listen": "0.0.0.0", "port": config["xray_port"],
            "protocol": "vless",
            "settings": {"clients": [{"id": identity["uuid"], "flow": "xtls-rprx-vision"}],
                         "decryption": "none"},
            "streamSettings": {
                "network": "raw", "security": "reality",
                "realitySettings": {
                    "show": False, "target": config["target"], "xver": 0,
                    "serverNames": [config["server_name"]],
                    "privateKey": identity["reality_private_key"],
                    "shortIds": [identity["short_id"]],
                },
            },
        }],
        "outbounds": [{"protocol": "freedom", "tag": "direct"}],
    }
    write(data / "xray.json", json.dumps(xray, indent=2) + "\n")
    write(data / "rathole/server.toml", f'''# Generated at startup; secrets live in identity.json.
[server]
bind_addr = "0.0.0.0:{config['rathole_port']}"
[server.transport]
type = "noise"
[server.transport.noise]
local_private_key = "{identity['noise_private_key']}"
[server.services.internal_https]
type = "tcp"
token = "{identity['rathole_token']}"
bind_addr = "0.0.0.0:443"
''')
    write(data / "rathole/client.toml", f'''# Copy securely to the internal host. Keep permissions 600.
[client]
remote_addr = "{authority(config['public_host'])}:{config['rathole_port']}"
[client.transport]
type = "noise"
[client.transport.noise]
remote_public_key = "{identity['noise_public_key']}"
[client.services.internal_https]
type = "tcp"
token = "{identity['rathole_token']}"
local_addr = "127.0.0.1:443"
''')
    query = urlencode({
        "encryption": "none", "security": "reality", "sni": config["server_name"],
        "fp": "chrome", "pbk": identity["reality_public_key"],
        "sid": identity["short_id"], "type": "tcp", "flow": "xtls-rprx-vision",
    })
    link = (f"vless://{identity['uuid']}@{authority(config['public_host'])}:"
            f"{config['xray_port']}?{query}#xLink-REALITY\n")
    write(data / "vless.txt", link)
    write(data / "health.json", json.dumps({"ports": [config["xray_port"], config["rathole_port"]]}))


def healthcheck(data, proc_net=Path("/proc/net")):
    config = json.loads((data / "health.json").read_text(encoding="utf-8"))
    listening = set()
    # Read this network namespace's socket table without opening connections:
    # a connect-and-close probe causes a Noise handshake error in rathole.
    for name in ("tcp", "tcp6"):
        path = proc_net / name
        if not path.exists():
            continue
        for line in path.read_text(encoding="ascii").splitlines()[1:]:
            fields = line.split()
            if len(fields) >= 4 and fields[3] == "0A":  # TCP_LISTEN
                listening.add(int(fields[1].rsplit(":", 1)[1], 16))
    missing = set(config["ports"]) - listening
    if missing:
        raise ValueError(f"Required TCP ports are not listening: {sorted(missing)}")
    # rathole listens on :443 only after an authenticated client connects.


def supervise(commands):
    children = []
    stopping = False

    def stop(signum, frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        for name, args in commands:
            if stopping:
                return 0
            children.append((name, subprocess.Popen(args)))
        while not stopping:
            for name, process in children:
                if process.poll() is not None:
                    print(f"{name} exited ({process.returncode}); stopping container", flush=True)
                    return 1
            time.sleep(0.2)
        return 0
    finally:
        for _, process in children:
            if process.poll() is None:
                process.terminate()
        deadline = time.monotonic() + 8
        for _, process in children:
            try:
                process.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    os.umask(0o077)
    action = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if action == "healthcheck":
        healthcheck(DATA)
        return 0
    if action == "info":
        print((DATA / "vless.txt").read_text(encoding="utf-8"), end="")
        return 0
    if action not in ("serve", "init"):
        raise ValueError("Usage: app.py [serve|init|info|healthcheck]")
    config = settings(os.environ)
    DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    DATA.chmod(0o700)
    render(DATA, config, identities(DATA))
    commands = [
        ("xray", ["xray", "run", "-config", str(DATA / "xray.json")]),
        ("rathole", ["rathole", "--server", str(DATA / "rathole/server.toml")]),
    ]
    # Validate Xray configuration before starting listeners.
    subprocess.run(["xray", "run", "-test", "-config", str(DATA / "xray.json")], check=True)
    print("xLink initialized; use 'docker exec xlink python3 /opt/xlink/app.py info' for the VLESS URI.", flush=True)
    print("rathole client config: /data/rathole/client.toml; :443 waits for an authenticated client.", flush=True)
    return 0 if action == "init" else supervise(commands)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Do not echo CLI output from key generation, which contains private keys.
        print(f"xLink: {error}", file=sys.stderr)
        sys.exit(1)
