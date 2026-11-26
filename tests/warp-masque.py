#!/usr/bin/env python3
import importlib.util, json, os, sys, tempfile
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("warp_masque",ROOT/"lib"/"warp_masque.py")
wm=importlib.util.module_from_spec(spec); sys.modules[spec.name]=wm; spec.loader.exec_module(wm)
cfg=dict(wm.DEFAULTS)

# Local Remnawave Backend access mirrors eGamesAPI's ProxyCheckMiddleware headers.
local_url, is_local = wm.normalize_panel_url("http://127.0.0.1:3000")
assert local_url == "http://127.0.0.1:3000" and is_local
assert wm.normalize_panel_url("http://localhost:3000")[1] is True
assert wm.normalize_panel_url("https://panel.example.com")[1] is False
for invalid_url in ("http://panel.example.com", "ftp://127.0.0.1:3000",
                    "https://user:pass@panel.example.com", "https://panel.example.com/path",
                    "https://panel.example.com/?token=secret"):
    try: wm.normalize_panel_url(invalid_url)
    except wm.WarpError: pass
    else: raise AssertionError(f"unsafe Panel API URL accepted: {invalid_url}")

local_headers = wm.panel_headers({"url": "http://127.0.0.1:3000", "token": "test-token"})
assert local_headers["Authorization"] == "Bearer test-token"
assert local_headers["X-Forwarded-For"] == "127.0.0.1"
assert local_headers["X-Forwarded-Proto"] == "https"
assert local_headers["X-Remnawave-Client-Type"] == "browser"
remote_headers = wm.panel_headers({"url": "https://panel.example.com", "token": "test-token"})
assert "X-Forwarded-For" not in remote_headers
assert "X-Forwarded-Proto" not in remote_headers
assert "X-Remnawave-Client-Type" not in remote_headers

# Verify panel_call routes local requests through the expected URL and headers.
with patch.object(wm, "http_json", return_value={"response": {"ok": True}}) as request:
    assert wm.panel_call({"url": "http://127.0.0.1:3000/", "token": "test-token"},
                         "GET", "/api/config-profiles") == {"ok": True}
    args = request.call_args.args
    assert args[0] == "http://127.0.0.1:3000/api/config-profiles"
    assert args[2]["X-Forwarded-Proto"] == "https"

# configure_panel defaults to local Backend and stores credentials with 0600 permissions.
with tempfile.TemporaryDirectory() as temp:
    local_cfg = dict(cfg)
    local_cfg["WARP_MASQUE_STATE_DIR"] = str(Path(temp) / "state")
    local_cfg["WARP_MASQUE_BACKUP_DIR"] = str(Path(temp) / "backup")
    with patch("builtins.input", return_value=""), patch.object(wm.getpass, "getpass", return_value="test-token"), \
         patch.object(wm, "panel_call", return_value={"configProfiles": [{"uuid": "profile-1"}]}) as api:
        saved = wm.configure_panel(local_cfg)
    assert saved == {"url": "http://127.0.0.1:3000", "token": "test-token"}
    api.assert_called_once()
    stored = wm.paths(local_cfg)["panel"]
    assert json.loads(stored.read_text()) == saved
    assert os.stat(stored).st_mode & 0o777 == 0o600

creds={"privateKey":"PRIVATE","publicKey":"PUBLIC","address":["172.16.0.2/32"],"endpoint":"162.159.198.2"}
out=wm.build_outbound(creds,cfg,"h2")
assert out["protocol"]=="masque"
assert out["streamSettings"]["network"]=="masque"
assert "method" not in out["streamSettings"]
assert out["streamSettings"]["security"]=="tls"
assert "warp" in out["streamSettings"]["masqueSettings"]
assert out["streamSettings"]["tlsSettings"]["alpn"]==["h2"]
assert wm.build_outbound(creds,cfg,"h3")["streamSettings"]["tlsSettings"]["alpn"]==["h3"]
assert wm.build_rule("all","warp-masque")=={"type":"field","outboundTag":"warp-masque"}
assert wm.build_rule("domains","warp-masque",["example.com"])["domain"]==["domain:example.com"]
rules=[{"type":"field","ip":["geoip:private"],"outboundTag":"BLOCK"},{"type":"field","outboundTag":"DIRECT"}]
wm.insert_before_fallback(rules,wm.build_rule("all","warp-masque"))
assert rules[1]["outboundTag"]=="warp-masque" and rules[2]["outboundTag"]=="DIRECT"
assert wm.endpoint_host("162.159.198.2:0")=="162.159.198.2"
assert wm.endpoint_host("[2606:4700:103::2]:0")=="2606:4700:103::2"
assert wm.endpoint_host("not-an-ip:443")==""
assert wm.validate_domains("example.com, sub.example.org")==["example.com","sub.example.org"]

# Declining the optional setup is safe for both keyboard layouts and undecodable bytes.
tty = type("TTY", (), {"isatty": lambda self: True})()
with patch.object(wm.sys, "stdin", tty), patch("builtins.input", return_value="т"), patch.object(wm, "enable_flow") as enable:
    assert wm.initial(cfg) == 10
    enable.assert_not_called()
with patch.object(wm.sys, "stdin", tty), patch("builtins.input", side_effect=UnicodeDecodeError("utf-8", bytes([0xd1]), 0, 1, "invalid start byte")), patch.object(wm, "enable_flow") as enable:
    assert wm.initial(cfg) == 10
    enable.assert_not_called()
with patch.object(wm.sys, "stdin", tty), patch("builtins.input", side_effect=["maybe", "n"]), patch.object(wm, "enable_flow") as enable:
    assert wm.initial(cfg) == 10
    enable.assert_not_called()

try: wm.validate_domains("https://example.com/path")
except wm.WarpError: pass
else: raise AssertionError("invalid domain accepted")

# Confirming the optional setup invokes the flow only after an explicit yes.
# enable_flow is mocked so this test cannot register a device or modify a Panel profile.
with patch.object(wm.sys, "stdin", tty), patch("builtins.input", return_value="y"), patch.object(wm, "enable_flow") as enable:
    assert wm.initial(cfg) == 0
    enable.assert_called_once_with(cfg)

print("WARP MASQUE unit tests passed.")
