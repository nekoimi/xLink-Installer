import base64
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import tomllib
import unittest
from urllib.parse import parse_qs, urlsplit


spec = importlib.util.spec_from_file_location("xlink", Path(__file__).parents[1] / "app.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


def key_output(args):
    if args[0] == "xray":
        return f"PrivateKey: {'A' * 43}\nPassword (PublicKey): {'B' * 43}\nHash32: ignored\n"
    key = base64.b64encode(bytes(range(32))).decode()
    return f"Private Key:\n{key}\nPublic Key:\n{key}\n"


class InitializationTests(unittest.TestCase):
    def test_restart_and_network_changes_keep_all_identities(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            identity = app.identities(data, key_output)
            first = app.settings({"PUBLIC_HOST": "vps.example.com"})
            app.render(data, first, identity)
            def no_generation(args):
                self.fail("A restart must not regenerate keys")

            second = app.settings({"PUBLIC_HOST": "new.example.com", "XRAY_PORT": "18443",
                                   "RATHOLE_PORT": "12333"})
            app.render(data, second, app.identities(data, no_generation))
            self.assertEqual(identity, json.loads((data / "identity.json").read_text()))
            self.assertIn("new.example.com:12333", (data / "rathole/client.toml").read_text())
            self.assertEqual(json.loads((data / "xray.json").read_text())["inbounds"][0]["port"], 18443)
            self.assertEqual(json.loads((data / "health.json").read_text())["ports"], [18443, 12333])

    def test_client_uri_and_noise_configs_match_server_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            identity = app.identities(data, key_output)
            app.render(data, app.settings({"PUBLIC_HOST": "2001:db8::1"}), identity)
            link = urlsplit((data / "vless.txt").read_text().strip())
            query = parse_qs(link.query)
            self.assertEqual(link.hostname, "2001:db8::1")
            self.assertEqual(link.username, identity["uuid"])
            self.assertEqual(query["pbk"], [identity["reality_public_key"]])
            self.assertEqual(query["sid"], [identity["short_id"]])
            self.assertEqual(query["flow"], ["xtls-rprx-vision"])
            server = tomllib.loads((data / "rathole/server.toml").read_text())["server"]
            client = tomllib.loads((data / "rathole/client.toml").read_text())["client"]
            self.assertEqual(server["services"]["internal_https"]["token"],
                             client["services"]["internal_https"]["token"])
            self.assertEqual(client["remote_addr"], "[2001:db8::1]:2333")
            self.assertEqual(json.loads((data / "health.json").read_text())["ports"], [8443, 2333])
            if os.name != "nt":
                self.assertEqual((data / "identity.json").stat().st_mode & 0o777, 0o600)

    def test_broken_identity_is_never_silently_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            saved = data / "identity.json"
            saved.write_text('{"uuid": "broken"}', encoding="utf-8")
            with self.assertRaises(ValueError):
                app.identities(data, lambda args: self.fail("Must not regenerate secrets"))
            self.assertEqual(saved.read_text(), '{"uuid": "broken"}')

    def test_invalid_settings_fail_before_generating_configs(self):
        cases = [
            {"PUBLIC_HOST": ""},
            {"PUBLIC_HOST": "example.com\n:443"},
            {"XRAY_PORT": "443"}, {"RATHOLE_PORT": "443"},
            {"XRAY_PORT": "2333"}, {"XRAY_PORT": "65536"},
            {"RATHOLE_PORT": "0"},
            {"REALITY_SERVER_NAME": "127.0.0.1"},
            {"REALITY_TARGET": "example.com:443/path"},
            {"REALITY_TARGET": "example.com:70000"},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                app.settings({"PUBLIC_HOST": "vps.example.com", **overrides})

    def test_only_tunnel_business_port_is_reserved(self):
        config = app.settings({"PUBLIC_HOST": "vps.example.com", "XRAY_PORT": "9443",
                               "RATHOLE_PORT": "80"})
        self.assertEqual(config["xray_port"], 9443)
        self.assertEqual(config["rathole_port"], 80)

    def test_healthcheck_needs_only_proxy_and_tunnel_control_listeners(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as listeners:
            ports = []
            for _ in range(2):
                listener = listeners.enter_context(socket.socket())
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                ports.append(listener.getsockname()[1])
            data = Path(directory)
            app.write(data / "health.json", json.dumps({"ports": ports}))
            app.healthcheck(data)


if __name__ == "__main__":
    unittest.main()
