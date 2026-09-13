"""Independent recount of the dashboard numbers straight from the raw CSVs.

Shares no code with the database: it re-implements the written rules in
Python so a bug in the SQL shows up as a mismatch. Run after seeding:

    python scripts/reconcile.py [data_dir]

and compare with the dashboard (or `npm run time-rpcs -- <brand>`).
"""
import csv
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

DATA = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
NOW = datetime.now(timezone.utc)

BRANDS = {
    "kilele": dict(code="KILELE", country="KE", contacts=["kilele-contacts.csv", "kilele-contacts-delta-2026-09-01.csv"],
                   campaigns="kilele-campaigns.csv", events="kilele-events.csv"),
    "karoo": dict(code="KAROO", country="ZA", contacts=["karoo-contacts.csv"], campaigns="karoo-campaigns.csv", events="karoo-events.csv"),
    "marrakech": dict(code="MARRAKECH", country="MA", contacts=["marrakech-contacts.csv"], campaigns="marrakech-campaigns.csv",
                      events="marrakech-events.csv"),
}
ALIASES = {
    "external_id": {"external_id", "externalid"}, "full_name": {"full_name"}, "email": {"email", "e_mail"},
    "phone": {"phone", "mobile"}, "country": {"country", "pays"}, "status": {"status"},
    "consent_marketing": {"consent_marketing"}, "deleted_at": {"deleted_at"}, "suppressed_until": {"suppressed_until"},
    "brand_code": {"brand_code"}, "signup_at": {"signup_at"},
}
EMAIL_RE = re.compile(r"^[a-z0-9._%+'-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$")
CODES = {"KE": "254", "ZA": "27", "MA": "212", "UG": "256", "TZ": "255", "RW": "250", "ET": "251", "SS": "211"}
COUNTRY = {"KEN": "KE", "KENYA": "KE", "254": "KE", "ZAF": "ZA", "SOUTH AFRICA": "ZA", "27": "ZA", "MAR": "MA", "MOROCCO": "MA",
           "MAROC": "MA", "212": "MA"}


def norm(h):
    return re.sub(r"[^a-z0-9]+", "_", h.replace("﻿", "").strip().lower()).strip("_")


def read(path):
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("cp1252")
    text = text.lstrip("﻿")
    first = text.split("\n", 1)[0]
    delim = ";" if first.count(";") > first.count(",") else ","
    rows = list(csv.reader(text.splitlines(True), delimiter=delim))
    return rows[0], rows[1:]


def parse_dt(s):
    s = (s or "").strip()
    if not s:
        return None, "empty"
    if re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z$", s):
        return datetime.fromisoformat(s.replace("Z", "+00:00")), "iso"
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        return datetime.fromisoformat(s), "date"
    if re.match(r"^\d{1,2}/\d{1,2}/\d{4}( \d{1,2}:\d{2})?$", s):
        try:
            return datetime.strptime(s, "%d/%m/%Y %H:%M" if " " in s else "%d/%m/%Y"), "ddmm"
        except ValueError:
            return None, "invalid"
    return None, "invalid"


def phone(raw, country):
    raw = (raw or "").strip()
    if not raw or re.match(r"^[0-9.]+[eE]\+?[0-9]+$", raw):
        return None
    d = re.sub(r"\D", "", raw)
    for cc in ["254", "27", "212", "256", "255", "250", "251", "211"]:
        if d.startswith(cc) and len(d) == len(cc) + 9:
            return "+" + d
    if re.match(r"^0[1-9]\d{8}$", d) and country in CODES:
        return "+" + CODES[country] + d[1:]
    return None


def reconcile(slug, cfg):
    contacts = {}
    for fname in cfg["contacts"]:  # later files (the delta) override earlier ones
        header, rows = read(DATA / fname)
        idx = {}
        for i, h in enumerate(header):
            for field, names in ALIASES.items():
                if norm(h) in names and field not in idx:
                    idx[field] = i
        hn = [norm(h) for h in header]
        for r in rows:
            if not r or all(not c.strip() for c in r) or len(r) != len(header) or [norm(c) for c in r] == hn:
                continue
            if any(ord(ch) < 32 and ch not in "\t\n\r" for ch in "".join(r)) or "\x00" in "".join(r):
                continue
            g = lambda f: r[idx[f]] if f in idx else ""
            if (g("brand_code").strip().upper() or None) != cfg["code"]:
                continue
            status = {"active": "active", "unsubscribed": "unsubscribed", "unsubscribe": "unsubscribed", "bounced": "bounced",
                      "bounce": "bounced", "pending": "pending"}.get(g("status").strip().lower())
            deleted, df = parse_dt(g("deleted_at"))
            supp, sf = parse_dt(g("suppressed_until"))
            if not status or df == "invalid" or sf == "invalid" or not re.match(r"^[A-Za-z0-9_.:-]{1,64}$", g("external_id").strip()):
                continue
            email = g("email").strip().lower()
            email = email if EMAIL_RE.match(email) and ".." not in email else None
            c = g("country").strip().upper()
            country = None if c in ("", "NONE", "NULL", "N/A", "NA", "-", "ZZ") else COUNTRY.get(c, c if re.match(r"^[A-Z]{2}$", c) else None)
            consent = {"true": True, "t": True, "1": True, "yes": True, "y": True}.get(g("consent_marketing").strip().lower(), False)
            contacts[g("external_id").strip()] = dict(
                deleted=deleted is not None, status=status, consent=consent,
                suppressed=supp is not None and supp.replace(tzinfo=supp.tzinfo or timezone.utc) > NOW,
                email=email, phone=phone(g("phone"), country or cfg["country"]))

    _, camp_rows = read(DATA / cfg["campaigns"])
    campaigns = {r[0].strip() for r in camp_rows if r}
    header, ev_rows = read(DATA / cfg["events"])
    seen, opted_out, bounced = set(), set(), defaultdict(set)
    for r in ev_rows:
        if len(r) != 6 or r[0] in seen:
            continue
        seen.add(r[0])
        cid, camp, etype, chan = r[1].strip(), r[2].strip(), r[3].strip().lower(), r[4].strip().lower()
        if cid not in contacts or camp not in campaigns:
            continue
        if etype in ("unsubscribe", "complaint"):
            opted_out.add(cid)
        elif etype == "bounce":
            bounced[cid].add(chan)

    n = defaultdict(int)
    for cid, c in contacts.items():
        n["contacts_in_database"] += 1
        if c["deleted"]:
            n["deleted"] += 1
            continue
        n["total_customers"] += 1
        email_ok = c["email"] is not None and "email" not in bounced[cid]
        sms_ok = c["phone"] is not None and "sms" not in bounced[cid]
        if c["status"] != "active":
            n["excluded_status"] += 1
        elif not c["consent"]:
            n["excluded_no_consent"] += 1
        elif c["suppressed"]:
            n["excluded_suppressed"] += 1
        elif cid in opted_out:
            n["excluded_opted_out"] += 1
        elif not email_ok and not sms_ok:
            n["excluded_no_address"] += 1
        else:
            n["contactable_any"] += 1
            n["contactable_email"] += email_ok
            n["contactable_sms"] += sms_ok
    return dict(n)


if __name__ == "__main__":
    for slug, cfg in BRANDS.items():
        print(slug, reconcile(slug, cfg))
