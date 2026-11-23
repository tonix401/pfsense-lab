#!/usr/bin/env python3
"""Fill pfSense web forms the way a browser would: load the page (with its defaults), override
some fields, submit. Used to set up Suricata, whose config is too large to write by hand.

    gui.py suricata              enable the ET Open ruleset
    gui.py suricata-interface    add + start Suricata on HOSTNET (after the rules are downloaded)
    gui.py home-net              set HOME_NET to the server net on an existing interface
"""
import html.parser
import http.cookiejar
import re
import ssl
import sys
import urllib.parse
import urllib.request

BASE = "https://192.168.56.10"
USER, PASSWORD = "admin", "pfsense"

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ctx),
)


class Form(html.parser.HTMLParser):
    """Collects the successful controls of the first <form> with a POST method."""

    def __init__(self):
        super().__init__()
        self.fields, self.in_form, self.done, self.select, self.textarea = [], False, False, None, None

    def handle_starttag(self, tag, a):
        a = dict(a)
        if tag == "form" and not self.done and a.get("method", "").lower() == "post":
            self.in_form = True
        if not self.in_form:
            return
        name = a.get("name")
        if tag == "input" and name:
            kind = a.get("type", "text").lower()
            if kind in ("submit", "button", "image", "reset", "file"):
                return
            if kind in ("checkbox", "radio") and "checked" not in a:
                return
            self.fields.append([name, a.get("value", "on" if kind == "checkbox" else "")])
        elif tag == "select" and name:
            self.select = [name, None, None]  # name, first option, selected option
        elif tag == "option" and self.select:
            v = a.get("value", "")
            if self.select[1] is None:
                self.select[1] = v
            if "selected" in a:
                self.select[2] = v
        elif tag == "textarea" and name:
            self.textarea = [name, ""]

    def handle_data(self, data):
        if self.textarea:
            self.textarea[1] += data

    def handle_endtag(self, tag):
        if tag == "select" and self.select:
            v = self.select[2] if self.select[2] is not None else self.select[1]
            if v is not None:
                self.fields.append([self.select[0], v])
            self.select = None
        elif tag == "textarea" and self.textarea:
            self.fields.append(self.textarea)
            self.textarea = None
        elif tag == "form" and self.in_form:
            self.in_form, self.done = False, True


def get(path):
    return opener.open(BASE + path, timeout=120).read().decode(errors="replace")


def post(path, fields):
    if not isinstance(fields, dict):
        fields = [tuple(x) for x in fields]
    data = urllib.parse.urlencode(fields).encode()
    return opener.open(BASE + path, data, timeout=600).read().decode(errors="replace")


def csrf(page):
    return re.search(r"var csrfMagicToken = \"([^\"]+)\"", page).group(1)


def submit(path, set_=None, drop=(), button=("save", "Save")):
    """Loads the form at path, applies overrides and posts it back with the given button."""
    page = get(path)
    f = Form()
    f.feed(page)
    fields = [x for x in f.fields if x[0] not in drop and x[0] not in (set_ or {})]
    # An empty override unticks a checkbox: the field is left out, as a browser would
    fields += [[k, v] for k, v in (set_ or {}).items() if v != ""]
    fields = [x for x in fields if x[0] != "__csrf_magic"] + [["__csrf_magic", csrf(page)]]
    if button:
        fields.append(list(button))
    out = post(path, fields)
    err = re.search(r"input_errors.*?<li>(.*?)</li>", out, re.S)
    if err:
        sys.exit(f"{path}: {err.group(1).strip()}")
    return out


def login():
    page = get("/")
    post("/", {"__csrf_magic": csrf(page), "usernamefld": USER, "passwordfld": PASSWORD, "login": "Sign In"})
    if "usernamefld" in get("/index.php"):
        sys.exit("login failed")


def suricata():
    login()
    # Global settings: free ET Open ruleset, refresh daily, keep alerts across restarts
    submit("/suricata/suricata_global.php", {
        "enable_etopen_rules": "on",
        "autoruleupdate": "1d_up",
        "clearlogs": "",
    })
    print("global settings saved")


def lab_home_net():
    """Pass list "labservers" = 10.10.10.0/24 only, used as Suricata's HOME_NET.

    The default HOME_NET is every attached subnet, host-only 192.168.56.0/24 included. The host
    then counts as internal, and the ET web-attack rules ($EXTERNAL_NET -> $HTTP_SERVERS) never
    fire for it. With only the server net as HOME_NET, the host is external.
    """
    submit("/suricata/suricata_passlist_edit.php?id=0", {
        "name": "labservers",
        "descr": "Lab servers behind pfSense (Suricata HOME_NET)",
        "localnets": "", "wangateips": "", "wandnsips": "", "vips": "", "vpnips": "",
        "address0": "10.10.10.0/24",
    })
    print("pass list labservers saved")


def suricata_interface():
    """Run after the rules are downloaded (suricata_check_for_rule_updates.php on pfSense)."""
    login()
    lab_home_net()
    # Interface: Suricata on HOSTNET (opt1), the attacker side, alert-only (legacy) mode
    submit("/suricata/suricata_interfaces_edit.php?id=0", {
        "interface": "opt1",
        "enable": "on",
        "descr": "HOSTNET",
        "homelistname": "labservers",
        "blockoffenders": "",  # alert only; blocking can be switched on for the demo
    })
    print("interface added")

    # Categories: everything relevant to scanning and web attacks on the DVWA host
    cats = ["emerging-scan.rules", "emerging-web_server.rules", "emerging-web_specific_apps.rules",
            "emerging-sql.rules", "emerging-attack_response.rules", "emerging-exploit.rules",
            "emerging-policy.rules", "emerging-info.rules", "emerging-shellcode.rules"]
    page = get("/suricata/suricata_rulesets.php?id=0")
    fields = [["__csrf_magic", csrf(page)], ["id", "0"], ["autoflowbits", "on"], ["save", "Save"]]
    fields += [["toenable[]", c] for c in cats]
    post("/suricata/suricata_rulesets.php?id=0", fields)
    print("categories enabled:", ", ".join(cats))

    # Start it (the interfaces list has a per-row start button)
    page = get("/suricata/suricata_interfaces.php")
    post("/suricata/suricata_interfaces.php", {"__csrf_magic": csrf(page), "toggle": "start", "id": "0"})
    print("start requested")



def fix_home_net():
    """Applies lab_home_net() to an existing Suricata interface and restarts it."""
    login()
    lab_home_net()
    submit("/suricata/suricata_interfaces_edit.php?id=0", {"homelistname": "labservers"})
    page = get("/suricata/suricata_interfaces.php")
    post("/suricata/suricata_interfaces.php", {"__csrf_magic": csrf(page), "toggle": "start", "id": "0"})
    print("HOME_NET set to labservers, Suricata restarted")


if __name__ == "__main__":
    {"suricata": suricata, "suricata-interface": suricata_interface, "home-net": fix_home_net}[sys.argv[1]]()
