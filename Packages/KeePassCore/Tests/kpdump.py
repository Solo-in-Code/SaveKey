# SPDX-License-Identifier: AGPL-3.0-or-later
"""Dump a KeePass database to normalised JSON (used to cross-check the Swift engine)."""
import sys, json, hashlib
from pykeepass import PyKeePass

def dump(path, password, keyfile):
    kp = PyKeePass(path, password=password, keyfile=keyfile)
    out = []
    for e in kp.entries:
        out.append({
            "uuid": str(e.uuid).upper(),
            "title": e.title or "", "username": e.username or "", "password": e.password or "",
            "url": e.url or "", "notes": (e.notes or "").replace("\r\n", "\n"),
            "tags": sorted(e.tags or []),
            "custom": {k: v or "" for k, v in sorted(e.custom_properties.items())},
            "attachments": sorted([[a.filename, hashlib.sha256(a.data).hexdigest()] for a in e.attachments]),
            "history": len(e.history),
            "group": "/".join((p or "") for p in (e.group.path or [])) if e.group else "",
        })
    out.sort(key=lambda x: x["uuid"])
    groups = sorted("/".join((p or "") for p in (g.path or [])) for g in kp.groups)
    return {"name": kp.database_name or "", "entries": out, "groups": groups,
            "version": list(kp.version), "cipher": kp.encryption_algorithm, "kdf": kp.kdf_algorithm}

if __name__ == "__main__":
    path, pw, kf = sys.argv[1], sys.argv[2], sys.argv[3]
    print(json.dumps(dump(path, None if pw == "-" else pw, None if kf == "-" else kf), indent=1, sort_keys=True, ensure_ascii=False))
