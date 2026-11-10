#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
reseller-api: endpoint HTTP kecil untuk bot Telegram (nobosel) di VPS script v5.

Endpoint (GET, semua butuh ?user=<username>&auth=<kunci>):
  /lockssh   /unlockssh   /addipssh
  /lockvmess /unlockvmess /addipvmess
  /lockvless /unlockvless /addipvless
  /locktrojan /unlocktrojan /addiptrojan

Tambah IP: /addip<jenis>?user=..&add=<jumlah>&max=<batas total>&auth=..

Cara kerja meniru script bawaan v5 (bot-lock*, bot-unlock*, bot-ganti-ip-*):
  - SSH    : passwd -l / passwd -u
  - Xray   : pindahkan entri akun antara /etc/xray/config.json <-> /etc/xray/.lock.db
  - Limit IP: file /etc/kyt/limit/<jenis>/ip/<user>
"""
import hmac
import json
import os
import pwd
import re
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("RESELLER_API_PORT", "5889"))
KEY_FILE = os.environ.get("RESELLER_API_KEY_FILE", "/etc/kyt/reseller-api.key")
XRAY_CONFIG = os.environ.get("XRAY_CONFIG", "/etc/xray/config.json")
LOCK_DB = os.environ.get("XRAY_LOCK_DB", "/etc/xray/.lock.db")
LIMIT_DIR = os.environ.get("KYT_LIMIT_DIR", "/etc/kyt/limit")
RESTART_CMD = os.environ.get("XRAY_RESTART_CMD", "systemctl restart xray").split()
HARD_MAX_IP = int(os.environ.get("HARD_MAX_IP", "20"))

USER_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
LOCK = threading.Lock()  # satu perubahan config pada satu waktu

# Format penanda per protokol (sama persis dengan script v5)
XRAY = {
    "vmess": {
        "tag": "###",
        "db_marker": "#vmess",
        "markers": ["#vmess", "#vmessgrpc"],
        "entry": '},{"id": "%(uuid)s","alterId": 0,"email": "%(user)s"',
    },
    "vless": {
        "tag": "#&",
        "db_marker": "#vless",
        "markers": ["#vless", "#vlessgrpc"],
        "entry": '},{"id": "%(uuid)s","email": "%(user)s"',
    },
    "trojan": {
        "tag": "#!",
        "db_marker": "#trojan",
        "markers": ["#trojanws", "#trojangrpc"],
        "entry": '},{"password": "%(uuid)s","email": "%(user)s"',
    },
}
CRED_RE = re.compile(r'"(?:id|password)":\s*"([^"]+)"')


class ApiError(Exception):
    pass


# ----------------------------------------------------------------- helpers
def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def write_atomic(path, text):
    directory = os.path.dirname(path) or "."
    mode = None
    try:
        mode = os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        pass
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-reseller-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def restart_xray():
    r = subprocess.run(RESTART_CMD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


# ---------------------------------------------------------------- limit IP
def limit_path(jenis, user):
    return os.path.join(LIMIT_DIR, jenis, "ip", user)


def add_ip(jenis, user, add, max_total):
    if add < 1:
        raise ApiError("Jumlah IP yang ditambah harus minimal 1.")
    cap = min(max_total, HARD_MAX_IP) if max_total > 0 else HARD_MAX_IP
    path = limit_path(jenis, user)
    # File limit bisa berisi beberapa baris kalau pernah diappend script renew lama:
    # pakai baris terakhir sebagai nilai berlaku, lalu tulis ulang jadi satu baris.
    baris = [l.strip() for l in read_text(path).split("\n") if l.strip()]
    if not baris:
        raise ApiError("File limit IP akun tidak ditemukan di server.")
    try:
        current = int(baris[-1])
    except ValueError:
        raise ApiError("Isi file limit IP tidak valid.")
    new = current + add
    if new > cap:
        raise ApiError("Limit IP melebihi batas maksimal (%d). Saat ini: %d." % (cap, current))
    write_atomic(path, "%d\n" % new)
    return {"before": current, "after": new}


# --------------------------------------------------------------------- SSH
def ssh_user_ok(user):
    try:
        entry = pwd.getpwnam(user)
    except KeyError:
        raise ApiError("Akun SSH tidak ditemukan.")
    if entry.pw_uid < 1000 or user == "nobody":
        raise ApiError("Akun ini tidak boleh dikelola.")


def ssh_locked(user):
    r = subprocess.run(["passwd", "-S", user], capture_output=True, text=True)
    parts = r.stdout.split()
    return len(parts) > 1 and parts[1] == "L"


def ssh_lock(user):
    ssh_user_ok(user)
    if ssh_locked(user):
        return {"note": "sudah terkunci"}
    r = subprocess.run(["passwd", "-l", user], capture_output=True)
    if r.returncode != 0:
        raise ApiError("Gagal mengunci akun SSH.")
    # putuskan sesi yang sedang berjalan agar lock langsung terasa
    subprocess.run(["pkill", "-KILL", "-u", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {}


def ssh_unlock(user):
    ssh_user_ok(user)
    if not ssh_locked(user):
        return {"note": "sudah aktif"}
    r = subprocess.run(["passwd", "-u", user], capture_output=True)
    if r.returncode != 0:
        raise ApiError("Gagal membuka kunci akun SSH.")
    return {}


# -------------------------------------------------------------------- Xray
def ensure_lock_db(text):
    lines = text.split("\n") if text else []
    while lines and lines[-1] == "":
        lines.pop()
    present = [l.rstrip() for l in lines]
    for marker in ("#vmess", "#vless", "#trojan"):
        if marker not in present:
            lines.append(marker)
            present.append(marker)
    return lines


def xray_lock(jenis, user):
    spec = XRAY[jenis]
    tag = spec["tag"]
    lines = read_text(XRAY_CONFIG).split("\n")
    out, i, uuid, exp, removed = [], 0, None, None, 0
    while i < len(lines):
        parts = lines[i].split(" ")
        if len(parts) >= 3 and parts[0] == tag and parts[1] == user:
            j = i + 1
            while j < len(lines) and not lines[j].startswith("},{"):
                j += 1
            if j < len(lines):
                m = CRED_RE.search(lines[j])
                if m and uuid is None:
                    uuid = m.group(1)
                if exp is None:
                    exp = parts[2]
                removed += 1
                i = j + 1
                continue
        out.append(lines[i])
        i += 1
    if not removed or not uuid:
        locked_text = read_text(LOCK_DB)
        for ln in locked_text.split("\n"):
            p = ln.split(" ")
            if len(p) >= 4 and p[0] == tag and p[1] == user:
                return {"note": "sudah terkunci"}
        raise ApiError("Akun %s tidak ditemukan di server." % jenis.upper())

    db_lines = ensure_lock_db(read_text(LOCK_DB))
    idx = [l.rstrip() for l in db_lines].index(spec["db_marker"])
    db_lines.insert(idx + 1, "%s %s %s %s" % (tag, user, exp, uuid))

    backup = XRAY_CONFIG + ".reseller.bak"
    original = "\n".join(lines)
    write_atomic(backup, original)
    write_atomic(LOCK_DB, "\n".join(db_lines) + "\n")
    write_atomic(XRAY_CONFIG, "\n".join(out))
    if not restart_xray():
        write_atomic(XRAY_CONFIG, original)
        write_atomic(LOCK_DB, "\n".join(l for l in db_lines if l != "%s %s %s %s" % (tag, user, exp, uuid)) + "\n")
        restart_xray()
        raise ApiError("Xray gagal restart, perubahan dibatalkan.")
    return {"exp": exp}


def xray_unlock(jenis, user):
    spec = XRAY[jenis]
    tag = spec["tag"]
    db_lines = read_text(LOCK_DB).split("\n")
    found = None
    for ln in db_lines:
        p = ln.split(" ")
        if len(p) >= 4 and p[0] == tag and p[1] == user:
            found = (ln, p[2], p[3])
            break
    cfg_lines = read_text(XRAY_CONFIG).split("\n")
    already = any(
        (lambda p: len(p) >= 3 and p[0] == tag and p[1] == user)(l.split(" ")) for l in cfg_lines
    )
    if already:
        if found:
            write_atomic(LOCK_DB, "\n".join(l for l in db_lines if l != found[0]))
        return {"note": "sudah aktif"}
    if not found:
        raise ApiError("Akun %s ini tidak dalam keadaan terkunci." % jenis.upper())

    raw, exp, uuid = found
    entry = spec["entry"] % {"uuid": uuid, "user": user}
    out = []
    for ln in cfg_lines:
        out.append(ln)
        if ln.rstrip() in spec["markers"]:
            out.append("%s %s %s" % (tag, user, exp))
            out.append(entry)

    original = "\n".join(cfg_lines)
    write_atomic(XRAY_CONFIG + ".reseller.bak", original)
    write_atomic(XRAY_CONFIG, "\n".join(out))
    if not restart_xray():
        write_atomic(XRAY_CONFIG, original)
        restart_xray()
        raise ApiError("Xray gagal restart, perubahan dibatalkan.")
    write_atomic(LOCK_DB, "\n".join(l for l in db_lines if l != raw))
    return {"exp": exp}


# ------------------------------------------------------------------ routing
ROUTE_RE = re.compile(r"^/(lock|unlock|addip)(ssh|vmess|vless|trojan)$")


def handle(action, jenis, user, q):
    if action == "addip":
        try:
            add = int(q.get("add", ["1"])[0])
            max_total = int(q.get("max", ["0"])[0])
        except ValueError:
            raise ApiError("Parameter add/max harus angka.")
        data = add_ip(jenis, user, add, max_total)
        return "Limit IP diperbarui.", data
    if jenis == "ssh":
        data = ssh_lock(user) if action == "lock" else ssh_unlock(user)
    else:
        data = xray_lock(jenis, user) if action == "lock" else xray_unlock(jenis, user)
    note = data.get("note")
    if note:
        return "Akun %s." % note, data
    return ("Akun dikunci." if action == "lock" else "Akun dibuka."), data


class Handler(BaseHTTPRequestHandler):
    server_version = "reseller-api"

    def log_message(self, fmt, *args):  # jangan pernah log query string (ada auth)
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        m = ROUTE_RE.match(url.path)
        if not m:
            return self._send(404, {"status": "error", "message": "Endpoint tidak ditemukan."})
        q = parse_qs(url.query)
        key = read_text(KEY_FILE).strip()
        given = q.get("auth", [""])[0]
        if not key or not hmac.compare_digest(key.encode(), given.encode()):
            time.sleep(0.5)
            return self._send(401, {"status": "error", "message": "Auth tidak valid."})
        user = q.get("user", [""])[0]
        if not USER_RE.match(user):
            return self._send(400, {"status": "error", "message": "Username tidak valid."})
        action, jenis = m.group(1), m.group(2)
        try:
            with LOCK:
                message, data = handle(action, jenis, user, q)
            print("OK %s%s %s" % (action, jenis, user), flush=True)
            self._send(200, {"status": "success", "message": message, "data": data})
        except ApiError as e:
            print("ERR %s%s %s: %s" % (action, jenis, user, e), flush=True)
            self._send(200, {"status": "error", "message": str(e)})
        except Exception as e:  # noqa
            print("EXC %s%s %s: %r" % (action, jenis, user, e), flush=True)
            self._send(500, {"status": "error", "message": "Kesalahan internal server."})


if __name__ == "__main__":
    print("reseller-api listen :%d" % PORT, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
