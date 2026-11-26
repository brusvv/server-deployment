#!/usr/bin/env python3
"""Optional Cloudflare WARP-over-MASQUE integration for Remnawave."""
from __future__ import annotations
import base64, datetime as dt, getpass, ipaddress, json, os, re, secrets
import shutil, socket, ssl, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = {
    "WARP_MASQUE_TRANSPORT": "h2", "WARP_MASQUE_TAG": "warp-masque",
    "WARP_MASQUE_ENDPOINT_PORT": "443", "WARP_MASQUE_SERVER_NAME": "consumer-masque.cloudflareclient.com",
    "WARP_MASQUE_API_URL": "https://api.cloudflareclient.com/v0a4471/reg",
    "WARP_MASQUE_PANEL_API_URL": "http://127.0.0.1:3000",
    "WARP_MASQUE_CLIENT_VERSION": "a-6.35-4471", "WARP_MASQUE_MIN_XRAY_VERSION": "26.10.31",
    "WARP_MASQUE_STATE_DIR": "/var/lib/server-deployment/warp-masque",
    "WARP_MASQUE_BACKUP_DIR": "/var/backups/server-deployment/warp-masque",
}
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$")

class WarpError(RuntimeError):
    pass

def load_settings():
    cfg = dict(DEFAULTS)
    path = ROOT / "config" / "warp-masque.env"
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            key, value = line.split("=", 1)
            if key.strip() in cfg: cfg[key.strip()] = value.strip().strip("'").strip('"')
    if cfg["WARP_MASQUE_TRANSPORT"] not in ("h2", "h3"): raise WarpError("Transport must be h2 or h3")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", cfg["WARP_MASQUE_TAG"]): raise WarpError("Invalid outbound tag")
    return cfg

def paths(cfg):
    state, backup = Path(cfg["WARP_MASQUE_STATE_DIR"]), Path(cfg["WARP_MASQUE_BACKUP_DIR"])
    return {"state":state, "backup":backup, "creds":state/"credentials.json",
            "panel":state/"panel-api.json", "managed":state/"managed-profiles.json"}

def write_secure(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700); os.chmod(path.parent, 0o700)
    fd, temp = tempfile.mkstemp(prefix="."+path.name+".", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(temp, path); os.chmod(path, 0o600)
    finally:
        if os.path.exists(temp): os.unlink(temp)

def read_json(path, default):
    if not path.exists(): return default
    if path.stat().st_mode & 0o077: raise WarpError(f"Unsafe permissions on {path}; expected 0600")
    try: return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e: raise WarpError(f"Cannot read {path}: {e}") from e

def save_json(path, value):
    write_secure(path, (json.dumps(value, ensure_ascii=False, indent=2)+"\n").encode())

def unwrap(data):
    return data.get("response", data) if isinstance(data, dict) else data

def http_json(url, method, headers, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=25) as res: raw = res.read()
    except urllib.error.HTTPError as e:
        detail = e.read(1024).decode("utf-8","replace")
        raise WarpError(f"HTTP {e.code} from API: {detail[:400]}") from None
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        raise WarpError(f"API request failed: {e}") from None
    try: return json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError): raise WarpError("API returned invalid JSON") from None

def is_loopback_host(host):
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False

def normalize_panel_url(value):
    try:
        parsed = urllib.parse.urlsplit(value.strip())
        host = parsed.hostname
        port = parsed.port
    except (AttributeError, ValueError):
        raise WarpError("Invalid Remnawave API URL") from None
    if parsed.scheme not in ("http", "https") or not host:
        raise WarpError("Remnawave API URL must use HTTP(S)")
    if parsed.username is not None or parsed.password is not None:
        raise WarpError("Credentials must not be embedded in the Remnawave API URL")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise WarpError("Remnawave API URL must not contain a path, query or fragment")
    local = is_loopback_host(host)
    if parsed.scheme == "http" and not local:
        raise WarpError("Plain HTTP is allowed only for a loopback Remnawave Backend URL")
    # Accessing .port above validates the port syntax and range.
    _ = port
    return value.strip().rstrip("/"), local

def panel_headers(panel):
    _, local = normalize_panel_url(panel["url"])
    headers = {
        "Authorization": "Bearer " + panel["token"],
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    # Remnawave's ProxyCheckMiddleware requires these only when talking
    # directly to the loopback Backend, bypassing Nginx/TLS like eGamesAPI.
    # Never spoof forwarded headers when using a public reverse-proxy URL.
    if local:
        headers.update({
            "X-Forwarded-For": "127.0.0.1",
            "X-Forwarded-Proto": "https",
            "X-Remnawave-Client-Type": "browser",
        })
    return headers

def panel_call(panel, method, path, body=None):
    url, _ = normalize_panel_url(panel["url"])
    return unwrap(http_json(url + path, method, panel_headers(panel), body))

def configure_panel(cfg):
    p = paths(cfg)
    old = read_json(p["panel"], {})
    default_url = old.get("url") or cfg.get("WARP_MASQUE_PANEL_API_URL", DEFAULTS["WARP_MASQUE_PANEL_API_URL"])
    entered_url = input(f"Remnawave API URL [{default_url}]: ").strip() or default_url
    url, local = normalize_panel_url(entered_url)
    token = getpass.getpass("Remnawave API token (hidden; blank keeps saved token): ").strip() or old.get("token", "")
    if not token:
        raise WarpError("API token is required")
    panel = {"url": url, "token": token}
    result = panel_call(panel, "GET", "/api/config-profiles")
    if not isinstance(result, dict) or not isinstance(result.get("configProfiles"), list):
        raise WarpError("Panel API response is incompatible; expected response.configProfiles")
    save_json(p["panel"], panel)
    if local:
        print("Using local Remnawave Backend; trusted reverse-proxy headers enabled.")
    else:
        print("Using HTTPS reverse-proxy URL; forwarded headers are provided by the proxy.")
    print(f"Panel API connected; {len(result['configProfiles'])} profiles found.")
    return panel

def get_panel(cfg):
    panel = read_json(paths(cfg)["panel"],{})
    if panel.get("url") and panel.get("token"): return panel
    return configure_panel(cfg)

def profiles(panel):
    result = panel_call(panel,"GET","/api/config-profiles")
    rows = result.get("configProfiles") if isinstance(result,dict) else None
    if not isinstance(rows,list): raise WarpError("Unexpected Config Profiles API response")
    return rows

def select_profile(panel):
    rows = profiles(panel)
    if not rows: raise WarpError("No Config Profiles found")
    print("\nRemnawave Config Profiles:")
    for i,row in enumerate(rows,1):
        nodes = ", ".join(n.get("name","?") for n in row.get("nodes",[])) or "no attached nodes"
        print(f"  {i}. {row.get('name')} | {row.get('uuid')} | {nodes}")
    value = input(f"Select [1-{len(rows)}]: ").strip()
    if not value.isdigit() or not 1 <= int(value) <= len(rows): raise WarpError("Invalid profile selection")
    return rows[int(value)-1]

def xray_version(cfg):
    commands=[]
    binary=shutil.which("xray")
    if binary: commands.append([binary,"version"])
    docker=shutil.which("docker")
    if docker:
        try: names=subprocess.check_output([docker,"ps","--format","{{.Names}}"],text=True,timeout=10).splitlines()
        except (OSError,subprocess.SubprocessError): names=[]
        for name in names:
            if "remnanode" in name.lower() or "xray" in name.lower():
                commands.extend([[docker,"exec",name,"xray","version"],[docker,"exec",name,"/usr/local/bin/xray","version"]])
    for command in commands:
        try: output=subprocess.check_output(command,text=True,stderr=subprocess.STDOUT,timeout=12)
        except (OSError,subprocess.SubprocessError): continue
        m=re.search(r"(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)",output)
        if m: return tuple(map(int,m.groups())), output.splitlines()[0]
    raise WarpError("Cannot verify Xray-core version locally or in a Remnawave Node container; refusing to apply MASQUE.")

def require_xray(cfg):
    version,label=xray_version(cfg)
    minimum=tuple(map(int,cfg["WARP_MASQUE_MIN_XRAY_VERSION"].split(".")))
    if version < minimum: raise WarpError(f"{label}: MASQUE requires Xray-core >= {cfg['WARP_MASQUE_MIN_XRAY_VERSION']}")
    print(f"Xray version OK: {label}")

def gen_p256():
    openssl=shutil.which("openssl")
    if not openssl: raise WarpError("OpenSSL is required")
    with tempfile.TemporaryDirectory(prefix="warp-masque-") as temp:
        key=Path(temp)/"key.pem"
        subprocess.run([openssl,"ecparam","-name","prime256v1","-genkey","-noout","-out",str(key)],check=True,stderr=subprocess.PIPE)
        private=subprocess.check_output([openssl,"ec","-in",str(key),"-outform","DER"],stderr=subprocess.DEVNULL)
        public=subprocess.check_output([openssl,"ec","-in",str(key),"-pubout","-outform","DER"],stderr=subprocess.DEVNULL)
    return base64.b64encode(private).decode(),base64.b64encode(public).decode()

def endpoint_host(value):
    if not isinstance(value,str) or not value: return ""
    value=value.strip()
    if value.startswith("["): value=value[1:].split("]",1)[0]
    elif value.count(":")==1: value=value.rsplit(":",1)[0]
    try: return str(ipaddress.ip_address(value))
    except ValueError: return ""

def register(cfg):
    print("\nCloudflare WARP MASQUE registration")
    print("The consumer registration endpoint is undocumented and may change.")
    print("Review Cloudflare WARP Terms: https://www.cloudflare.com/application/terms/")
    print("A new device is created; old registrations are not revoked automatically.")
    if input("Read and accept Cloudflare's Terms of Service? Type ACCEPT: ").strip()!="ACCEPT":
        raise WarpError("Registration cancelled")
    private,public=gen_p256()
    base=cfg["WARP_MASQUE_API_URL"].rstrip("/")
    headers={"User-Agent":"WARP for Android","CF-Client-Version":cfg["WARP_MASQUE_CLIENT_VERSION"],
             "Accept":"application/json","Content-Type":"application/json"}
    tos=dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")
    first=http_json(base,"POST",headers,{
        "key":base64.b64encode(secrets.token_bytes(32)).decode(),"install_id":"","fcm_token":"",
        "tos":tos,"model":"PC","serial_number":secrets.token_bytes(8).hex(),
        "os_version":"10","key_type":"curve25519","tunnel_type":"wireguard","locale":"en_US"})
    device,token=first.get("id"),first.get("token")
    if not device or not token: raise WarpError("Cloudflare registration returned no device id/token")
    h=dict(headers); h["Authorization"]="Bearer "+token
    enrolled=http_json(base+"/"+urllib.parse.quote(str(device),safe=""),"PATCH",h,{
        "key":public,"key_type":"secp256r1","tunnel_type":"masque","name":"server-deployment"})
    config=enrolled.get("config",{}); peers=config.get("peers") or []
    addresses=config.get("interface",{}).get("addresses",{})
    if not peers or not peers[0].get("public_key"): raise WarpError("Cloudflare returned no MASQUE endpoint public key")
    endpoint=endpoint_host((peers[0].get("endpoint") or {}).get("v4","")) or endpoint_host((peers[0].get("endpoint") or {}).get("v6",""))
    if not endpoint: raise WarpError("Cloudflare returned no valid MASQUE endpoint")
    assigned=[]
    for family in ("v4","v6"):
        value=addresses.get(family)
        if value:
            try: assigned.append(str(ipaddress.ip_interface(value)))
            except ValueError: assigned.append(str(ipaddress.ip_address(value)))
    if not assigned: raise WarpError("Cloudflare returned no tunnel addresses")
    return {"registrationId":str(device),"privateKey":private,"publicKey":peers[0]["public_key"],
            "address":assigned,"endpoint":endpoint,"registeredAt":dt.datetime.now(dt.timezone.utc).isoformat()}

def build_outbound(creds,cfg,transport=None):
    transport=transport or cfg["WARP_MASQUE_TRANSPORT"]
    if transport not in ("h2","h3"): raise WarpError("Transport must be h2 or h3")
    return {"tag":cfg["WARP_MASQUE_TAG"],"protocol":"masque",
        "settings":{"address":creds["endpoint"],"port":int(cfg["WARP_MASQUE_ENDPOINT_PORT"])},
        "streamSettings":{"network":"masque","security":"tls",
            "tlsSettings":{"serverName":cfg["WARP_MASQUE_SERVER_NAME"],"alpn":[transport]},
            "masqueSettings":{"warp":{
                "privateKey":creds["privateKey"],"publicKey":creds["publicKey"],"address":creds["address"]}}}}

def build_rule(mode,tag,domains=None):
    if mode=="none": return None
    if mode=="all": return {"type":"field","outboundTag":tag}
    if mode=="domains" and domains: return {"type":"field","domain":["domain:"+d for d in domains],"outboundTag":tag}
    raise WarpError("Invalid routing policy")

def is_catch_all(rule):
    keys=("inboundTag","domain","ip","port","source","user","protocol","attrs","network","sourcePort")
    return isinstance(rule,dict) and not any(k in rule for k in keys)

def insert_before_fallback(rules, rule):
    index=next((i for i,item in enumerate(rules) if is_catch_all(item)),len(rules))
    rules.insert(index,rule)

def validate_domains(raw):
    result=[]
    for item in re.split(r"[\s,;]+",raw.strip()):
        if not item: continue
        domain=item.removeprefix("domain:").lower().rstrip(".")
        if not DOMAIN_RE.fullmatch(domain): raise WarpError(f"Invalid domain: {item}")
        if domain not in result: result.append(domain)
    return result

def get_profile(panel,uuid):
    result=panel_call(panel,"GET","/api/config-profiles/"+urllib.parse.quote(uuid,safe=""))
    if isinstance(result,dict) and isinstance(result.get("configProfile"),dict): result=result["configProfile"]
    if not isinstance(result,dict) or result.get("uuid")!=uuid or not isinstance(result.get("config"),dict):
        raise WarpError("Unexpected Config Profile response or UUID mismatch")
    return result

def inspect_profile(panel, uuid):
    """Read a Config Profile and print a secret-safe structural summary only."""
    profile = get_profile(panel, uuid)
    config = profile["config"]
    inbounds = config.get("inbounds", [])
    outbounds = config.get("outbounds", [])
    routing = config.get("routing", {})
    rules = routing.get("rules", []) if isinstance(routing, dict) else []
    if not isinstance(inbounds, list) or not isinstance(outbounds, list) or not isinstance(rules, list):
        raise WarpError("Config Profile contains an unexpected inbound/outbound/routing structure")
    nodes = profile.get("nodes") or []
    print("\nConfig Profile read-only inspection")
    print(f"Name: {profile.get('name', 'unnamed')}")
    print(f"UUID: {profile['uuid']}")
    print(f"Attached Nodes: {len(nodes)}")
    for node in nodes:
        print(f"  - {node.get('name', 'unnamed')} ({node.get('uuid', 'unknown UUID')})")
    print(f"Inbounds: {len(inbounds)}")
    for item in inbounds:
        if isinstance(item, dict):
            print(f"  - {item.get('tag', 'untagged')} | {item.get('protocol', 'unknown')} | port {item.get('port', 'unknown')}")
    print(f"Outbounds: {len(outbounds)}")
    for item in outbounds:
        if isinstance(item, dict):
            print(f"  - {item.get('tag', 'untagged')} | {item.get('protocol', 'unknown')}")
    print(f"Routing rules: {len(rules)}")
    safe_rule_fields = ("type", "inboundTag", "domain", "ip", "port", "network", "protocol", "outboundTag")
    for index, rule in enumerate(rules, 1):
        if not isinstance(rule, dict):
            print(f"  {index}. [non-object rule]")
            continue
        parts = []
        for key in safe_rule_fields:
            value = rule.get(key)
            if value is None:
                continue
            if isinstance(value, list):
                rendered = ", ".join(str(item) for item in value)
            else:
                rendered = str(value)
            if len(rendered) > 180:
                rendered = rendered[:177] + "..."
            parts.append(f"{key}={rendered}")
        print(f"  {index}. " + ("; ".join(parts) if parts else "[no standard match fields]"))
    print("Secrets and raw config values were not displayed; no changes were made.")
    return profile

def backup_profile(profile,cfg):
    stamp=dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path=paths(cfg)["backup"]/str(profile["uuid"])/f"profile-{stamp}.json"
    save_json(path,profile); print(f"Profile backup: {path}")

def confirm_single_node_scope(profile):
    nodes=profile.get("nodes") or []
    if len(nodes)!=1:
        raise WarpError(f"WARP profile changes require exactly one attached Node; found {len(nodes)}. Split shared profiles before proceeding.")
    node=nodes[0]
    node_name=node.get("name") or node.get("uuid") or "unnamed Node"
    node_uuid=node.get("uuid","unknown UUID")
    print(f"Selected Config Profile: {profile.get('name')} ({profile.get('uuid')})")
    print(f"Attached Node: {node_name} ({node_uuid})")
    print("The manager cannot independently prove this Node is the VPS where it is running.")
    if input("Confirm this is the local VPS Node? Type LOCAL: ").strip()!="LOCAL":
        raise WarpError("Local Node confirmation failed; no profile changes were made.")

def patch_profile(panel,profile,config,cfg):
    backup_profile(profile,cfg)
    panel_call(panel,"PATCH","/api/config-profiles",{"uuid":profile["uuid"],"config":config})
    check=get_profile(panel,profile["uuid"])
    if check["config"]!=config:
        try: panel_call(panel,"PATCH","/api/config-profiles",{"uuid":profile["uuid"],"config":profile["config"]})
        except WarpError: pass
        raise WarpError("Panel did not confirm the new config; rollback was attempted")

def update_profile(panel,uuid,creds,cfg,mode,domains=None):
    require_xray(cfg)
    p=paths(cfg); managed=read_json(p["managed"],{})
    profile=get_profile(panel,uuid); config=json.loads(json.dumps(profile["config"]))
    record=managed.get(uuid); tag=cfg["WARP_MASQUE_TAG"]
    outbounds=config.setdefault("outbounds",[])
    if not isinstance(outbounds,list): raise WarpError("Profile outbounds is not an array")
    found=[x for x in outbounds if isinstance(x,dict) and x.get("tag")==tag]
    outbound=build_outbound(creds,cfg)
    if found:
        if len(found)!=1 or not record or found[0]!=record.get("outbound"):
            raise WarpError(f"Outbound tag {tag} already exists or was edited outside this manager")
        outbounds[outbounds.index(found[0])]=outbound
    else:
        if record: raise WarpError("Managed outbound disappeared; inspect profile before continuing")
        outbounds.append(outbound)
    routing=config.setdefault("routing",{})
    if not isinstance(routing,dict): raise WarpError("Profile routing is not an object")
    rules=routing.setdefault("rules",[])
    if not isinstance(rules,list): raise WarpError("Profile routing.rules is not an array")
    old=record.get("rule") if record else None
    if old is not None:
        if old not in rules: raise WarpError("Managed route rule was changed manually")
        rules.remove(old)
    rule=build_rule(mode,tag,domains)
    if rule is not None:
        insert_before_fallback(rules,rule)
    if any(isinstance(x,dict) and x.get("outboundTag")==tag and x!=rule for x in rules):
        raise WarpError("Other routing rules reference the WARP tag; resolve them manually")
    confirm_single_node_scope(profile)
    patch_profile(panel,profile,config,cfg)
    managed[uuid]={"profileName":profile.get("name",""),"outbound":outbound,"rule":rule,
                   "transport":cfg["WARP_MASQUE_TRANSPORT"],"routeMode":mode,"domains":domains or []}
    save_json(p["managed"],managed)
    print(f"WARP MASQUE updated in Config Profile {profile.get('name')}; verify Node rollout in Panel.")

def disable_profile(panel,uuid,cfg):
    p=paths(cfg); managed=read_json(p["managed"],{}); record=managed.get(uuid)
    if not record: raise WarpError("Profile is not managed by this tool")
    profile=get_profile(panel,uuid)
    confirm_single_node_scope(profile)
    config=json.loads(json.dumps(profile["config"])); tag=cfg["WARP_MASQUE_TAG"]
    outbounds=config.get("outbounds",[])
    found=[x for x in outbounds if isinstance(x,dict) and x.get("tag")==tag]
    if len(found)!=1 or found[0]!=record.get("outbound"): raise WarpError("Managed outbound missing/modified; refusing cleanup")
    outbounds.remove(found[0])
    routing=config.get("routing",{}); rules=routing.get("rules",[]) if isinstance(routing,dict) else []
    old=record.get("rule")
    if old is not None:
        if old not in rules: raise WarpError("Managed routing rule missing/modified; refusing cleanup")
        rules.remove(old)
    if any(isinstance(x,dict) and x.get("outboundTag")==tag for x in rules):
        raise WarpError("Other routing rules still reference WARP; remove them manually first")
    patch_profile(panel,profile,config,cfg); managed.pop(uuid,None); save_json(p["managed"],managed)
    print("WARP outbound removed. Registration credentials retained for later re-enable.")

def register_or_replace(cfg):
    p=paths(cfg); current=read_json(p["creds"],{})
    if current and input("Create a NEW WARP device registration? Type REGISTER: ").strip()!="REGISTER":
        print("Registration unchanged."); return
    creds=register(cfg)
    if current:
        stamp=dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        save_json(p["backup"]/"credentials"/f"credentials-{stamp}.json",current)
    save_json(p["creds"],creds)
    print("WARP credentials saved securely (0600); private key was not displayed.")

def enable_flow(cfg):
    p=paths(cfg); creds=read_json(p["creds"],{})
    if not creds: register_or_replace(cfg); creds=read_json(p["creds"],{})
    if not creds: raise WarpError("No WARP credentials available")
    panel=get_panel(cfg); profile=select_profile(panel)
    previous=read_json(p["managed"],{}).get(profile["uuid"],{})
    cfg["WARP_MASQUE_TRANSPORT"]=previous.get("transport",cfg["WARP_MASQUE_TRANSPORT"])
    print("\nRouting policy: 0=outbound only (default), 1=unmatched traffic, 2=selected domains")
    choice=input("Select [0/1/2]: ").strip() or "0"
    if choice=="0": mode,domains="none",[]
    elif choice=="1": mode,domains="all",[]
    elif choice=="2": mode,domains="domains",validate_domains(input("Domains: "))
    else: raise WarpError("Invalid routing choice")
    transport=input(f"Transport h2/h3 [{cfg['WARP_MASQUE_TRANSPORT']}]: ").strip().lower()
    if transport:
        if transport not in ("h2","h3"): raise WarpError("Transport must be h2 or h3")
        cfg["WARP_MASQUE_TRANSPORT"]=transport
    update_profile(panel,profile["uuid"],creds,cfg,mode,domains)

def managed_profile(panel,cfg):
    managed=read_json(paths(cfg)["managed"],{})
    rows=[(uuid,item) for uuid,item in managed.items()]
    if not rows: raise WarpError("No managed WARP profiles")
    print("\nManaged profiles:")
    for i,(uuid,item) in enumerate(rows,1): print(f"  {i}. {item.get('profileName')} | {uuid} | {item.get('transport')} | {item.get('routeMode')}")
    value=input(f"Select [1-{len(rows)}]: ").strip()
    if not value.isdigit() or not 1<=int(value)<=len(rows): raise WarpError("Invalid selection")
    return rows[int(value)-1][0]

def probe(cfg):
    creds=read_json(paths(cfg)["creds"],{})
    if not creds: raise WarpError("No WARP registration")
    host,port=creds["endpoint"],int(cfg["WARP_MASQUE_ENDPOINT_PORT"])
    if cfg["WARP_MASQUE_TRANSPORT"]=="h3":
        infos=socket.getaddrinfo(host,port,type=socket.SOCK_DGRAM)
        last_error=None
        for family,socktype,proto,_,sockaddr in infos:
            try:
                with socket.socket(family,socktype,proto) as sock:
                    sock.settimeout(3)
                    sock.sendto(b"",sockaddr)
                print("UDP datagram sent; this is only a reachability hint, not a QUIC/MASQUE handshake test.")
                return
            except OSError as exc:
                last_error=exc
        raise WarpError(f"UDP endpoint probe failed: {last_error}")
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); context.check_hostname=False
    context.verify_mode=ssl.CERT_NONE; context.set_alpn_protocols(["h2"])
    with socket.create_connection((host,port),timeout=7) as raw:
        with context.wrap_socket(raw,server_hostname=cfg["WARP_MASQUE_SERVER_NAME"]) as tls:
            if tls.selected_alpn_protocol()!="h2": raise WarpError("Endpoint did not negotiate h2")
            cert_pem=ssl.DER_cert_to_PEM_cert(tls.getpeercert(binary_form=True))
    openssl=shutil.which("openssl")
    if not openssl: raise WarpError("OpenSSL is required to verify the MASQUE endpoint certificate pin")
    with tempfile.TemporaryDirectory(prefix="warp-masque-probe-") as temp:
        cert_file=Path(temp)/"peer.pem"; cert_file.write_text(cert_pem)
        peer_pem=subprocess.check_output([openssl,"x509","-in",str(cert_file),"-pubkey","-noout"])
        peer_der=subprocess.check_output([openssl,"pkey","-pubin","-outform","DER"],input=peer_pem)
    expected=creds["publicKey"]
    if "BEGIN PUBLIC KEY" in expected:
        encoded="".join(line for line in expected.splitlines() if not line.startswith("-----"))
        expected_der=base64.b64decode(encoded)
    else:
        expected_der=base64.b64decode(expected)
    if peer_der!=expected_der: raise WarpError("MASQUE endpoint public-key pin does not match the registered device")
    print("TLS + ALPN h2 and MASQUE endpoint public-key pin verified; WARP egress is not yet verified.")

def menu(cfg):
    while True:
        print("\n=== Cloudflare WARP / MASQUE ===")
        print("1. Configure Remnawave API")
        print("2. Register / re-register WARP device")
        print("3. Enable / update WARP in Config Profile")
        print("4. Change routing policy")
        print("5. Switch transport (HTTP/2 / HTTP/3)")
        print("6. Disable WARP in Config Profile")
        print("7. Status / endpoint probe")
        print("8. Inspect Config Profile (read-only)")
        print("0. Back")
        choice=input("Select: ").strip()
        try:
            if choice=="0": return
            if choice=="1": configure_panel(cfg)
            elif choice=="2": register_or_replace(cfg)
            elif choice=="3": enable_flow(cfg)
            elif choice in ("4","5"):
                panel=get_panel(cfg); uuid=managed_profile(panel,cfg)
                creds=read_json(paths(cfg)["creds"],{}); record=read_json(paths(cfg)["managed"],{})[uuid]
                mode,domains=record.get("routeMode","none"),record.get("domains",[])
                cfg["WARP_MASQUE_TRANSPORT"]=record.get("transport","h2")
                if choice=="4":
                    pick=input("Routing: 0=outbound only, 1=unmatched traffic, 2=domains: ").strip()
                    if pick=="0": mode,domains="none",[]
                    elif pick=="1": mode,domains="all",[]
                    elif pick=="2": mode,domains="domains",validate_domains(input("Domains: "))
                    else: raise WarpError("Invalid routing choice")
                else:
                    pick=input(f"Transport h2/h3 [{record.get('transport','h2')}]: ").strip().lower()
                    if pick:
                        if pick not in ("h2","h3"): raise WarpError("Transport must be h2 or h3")
                        cfg["WARP_MASQUE_TRANSPORT"]=pick
                update_profile(panel,uuid,creds,cfg,mode,domains)
            elif choice=="6":
                panel=get_panel(cfg); uuid=managed_profile(panel,cfg)
                if input("Remove WARP outbound and managed route? Type DISABLE: ").strip()=="DISABLE":
                    disable_profile(panel,uuid,cfg)
                else: print("Cancelled.")
            elif choice=="7":
                creds=read_json(paths(cfg)["creds"],{}); managed=read_json(paths(cfg)["managed"],{})
                print(f"Registration: {'present' if creds else 'not registered'}")
                print(f"Managed Config Profiles: {len(managed)}")
                if creds: print(f"Endpoint: {creds.get('endpoint')}:{cfg['WARP_MASQUE_ENDPOINT_PORT']}; addresses: {', '.join(creds.get('address',[]))}")
                if creds: probe(cfg)
            elif choice=="8":
                panel=get_panel(cfg); profile=select_profile(panel)
                inspect_profile(panel, profile["uuid"])
            else: print("Unknown selection.")
        except (WarpError,OSError,ValueError,KeyError) as exc: print(f"ERROR: {exc}",file=sys.stderr)

def initial(cfg):
    if not sys.stdin.isatty():
        print("Non-interactive run: WARP MASQUE remains disabled by default."); return 10
    while True:
        try:
            answer = input("Configure optional Cloudflare WARP via Xray MASQUE now? [y/N] ").strip().casefold()
        except (UnicodeDecodeError, EOFError):
            print("Could not decode terminal input; WARP/MASQUE was safely skipped. Configure later with ./manage.sh.")
            return 10
        if answer in ("", "n", "no", "т", "нет"):
            print("Skipped; configure later with ./manage.sh."); return 10
        if answer in ("y", "yes", "д", "да"):
            enable_flow(cfg)
            return 0
        print("Please answer y/yes or n/no (also accepts Russian layout: д/т).")

def main():
    cfg=load_settings(); command=sys.argv[1] if len(sys.argv)>1 else "menu"
    if command=="menu": menu(cfg)
    elif command=="initial": sys.exit(initial(cfg) or 0)
    elif command=="status":
        p=paths(cfg); print(f"Registration: {'present' if read_json(p['creds'],{}) else 'not registered'}")
        print(f"Managed profiles: {len(read_json(p['managed'],{}))}")
    else: raise WarpError("Usage: warp_masque.py [menu|initial|status]")

if __name__=="__main__":
    try: main()
    except (WarpError,OSError,ValueError,KeyError) as exc:
        print(f"ERROR: {exc}",file=sys.stderr); sys.exit(1)
