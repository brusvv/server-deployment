#!/usr/bin/env python3
import importlib.util, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("warp_masque",ROOT/"lib"/"warp_masque.py")
wm=importlib.util.module_from_spec(spec); sys.modules[spec.name]=wm; spec.loader.exec_module(wm)
cfg=dict(wm.DEFAULTS)
creds={"privateKey":"PRIVATE","publicKey":"PUBLIC","address":["172.16.0.2/32"],"endpoint":"162.159.198.2"}
out=wm.build_outbound(creds,cfg,"h2")
assert out["protocol"]=="masque" and out["streamSettings"]["method"]=="masque"
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
try: wm.validate_domains("https://example.com/path")
except wm.WarpError: pass
else: raise AssertionError("invalid domain accepted")
print("WARP MASQUE unit tests passed.")
