#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML>=6.0.1"]
# ///
"""dnsctl -- read the zones/ tree, check it, and compare it with reality.

Terraform is what applies. This is what refuses.

    validate   parse and check the tree; exit non-zero on any error
    build      write the document that policy/*.rego is evaluated against
    render     print every record the tree produces
    verify     ask the public DNS whether zone.yaml is still true
    drift      ask Cloudflare what it holds that this repository does not
    import-blocks  write the Terraform import blocks that adopt a live zone

The mapping from the tree to records is implemented twice: here and in
terraform/modules/zone/locals.tf. `make render-diff` diffs the two. Change one,
change the other.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

# Cloudflare stores host-name content without a trailing dot. Trimming is
# confined to these types: a TXT value that ends in a dot ends in a dot on
# purpose.
HOSTNAME_TYPES = {"CNAME", "MX", "NS", "PTR", "SRV"}

# What a team may write in its own records.yaml. An allowlist, so a record type
# nobody has thought about yet is refused rather than permitted.
SERVICE_RECORD_TYPES = {"A", "AAAA", "CNAME", "TXT"}

# Everything Cloudflare will accept anywhere. apex/ is deliberately not
# restricted beyond this: critical approvers own it, and it is the escape hatch
# for the record type this design did not foresee.
CLOUDFLARE_RECORD_TYPES = {
    "A", "AAAA", "CAA", "CERT", "CNAME", "DNSKEY", "DS", "HTTPS", "LOC", "MX",
    "NAPTR", "NS", "OPENPGPKEY", "PTR", "SMIMEA", "SRV", "SSHFP", "SVCB",
    "TLSA", "TXT", "URI",
}

RECORD_KEYS = {"name", "type", "values", "ttl", "priority", "proxied", "comment"}
ZONE_KEYS = {"zone", "zone_id", "account_id", "dnssec", "nameservers", "ttl"}
SERVICE_KEYS = {"owner", "expires", "delegation"}
DELEGATION_KEYS = {"type", "nameservers", "expires"}
VALIDATION_KEYS = {"vendor", "requested_by", "purpose", "expires", "txt", "cname"}


# --------------------------------------------------------------------------
# strict YAML
# --------------------------------------------------------------------------

class DuplicateKeyError(Exception):
    pass


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses a duplicate mapping key.

    A map of names has a failure mode a list of records does not. Most parsers
    accept a duplicate key, keep the last one and say nothing, so a second
    `_hubspot:` deletes the first and the reviewer sees a diff that adds a line.
    """


def _no_duplicate_keys(loader: StrictLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    mapping: dict = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            mark = key_node.start_mark
            raise DuplicateKeyError(
                f"line {mark.line + 1}, column {mark.column + 1}: duplicate key {key!r} "
                f"-- the second one would silently replace the first"
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicate_keys
)


# --------------------------------------------------------------------------
# findings
# --------------------------------------------------------------------------

@dataclass
class Finding:
    level: str  # "error" | "warning"
    path: str
    message: str

    def __str__(self) -> str:
        tag = "ERROR" if self.level == "error" else "warn "
        return f"{tag}  {self.path}: {self.message}"


@dataclass
class Record:
    """One rendered record: exactly what Terraform will ask Cloudflare for."""
    zone: str
    source: str
    name: str
    type: str
    content: str
    ttl: int
    proxied: bool
    priority: int | None

    @property
    def key(self) -> str:
        return f"{self.name}|{self.type}|{self.content}"

    def as_dict(self) -> dict:
        return {
            "zone": self.zone, "source": self.source, "name": self.name,
            "type": self.type, "content": self.content, "ttl": self.ttl,
            "proxied": self.proxied, "priority": self.priority,
        }


# --------------------------------------------------------------------------
# loading
# --------------------------------------------------------------------------

def _jsonable(value: Any) -> Any:
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: _jsonable(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_jsonable(v) for v in value]
    return value


class Zone:
    def __init__(self, root: Path, directory: Path) -> None:
        self.root = root
        self.dir = directory
        self.name = directory.name
        self.findings: list[Finding] = []
        self.config: dict = {}
        self.services: list[dict] = []
        self.validations: list[dict] = []
        self.files: list[dict] = []
        self.records: list[Record] = []

    # -- helpers -----------------------------------------------------------

    def rel(self, path: Path) -> str:
        return path.relative_to(self.root).as_posix()

    def error(self, path: Path | str, message: str) -> None:
        self.findings.append(Finding("error", path if isinstance(path, str) else self.rel(path), message))

    def warn(self, path: Path | str, message: str) -> None:
        self.findings.append(Finding("warning", path if isinstance(path, str) else self.rel(path), message))

    def _load(self, path: Path) -> Any:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            self.error(path, f"cannot read: {exc}")
            return None
        try:
            return yaml.load(text, Loader=StrictLoader)
        except DuplicateKeyError as exc:
            self.error(path, str(exc))
        except yaml.YAMLError as exc:
            self.error(path, f"not valid YAML: {str(exc).splitlines()[0]}")
        return None

    def _check_keys(self, path: Path, doc: dict, allowed: set[str], what: str) -> None:
        for key in sorted(set(doc) - allowed):
            self.error(path, f"unknown key {key!r} in {what} -- allowed: {', '.join(sorted(allowed))}")

    # -- the tree ----------------------------------------------------------

    def load(self) -> None:
        self._load_zone_config()
        self._load_services()
        self._load_apex()
        self._load_validations()
        self._load_service_records()
        self._load_delegations()

    def _load_zone_config(self) -> None:
        path = self.dir / "zone.yaml"
        if not path.is_file():
            self.error(self.rel(self.dir), "no zone.yaml -- a zone directory must declare itself")
            return
        doc = self._load(path)
        if doc is None:
            return
        if not isinstance(doc, dict):
            self.error(path, "must be a mapping")
            return
        self._check_keys(path, doc, ZONE_KEYS, "zone.yaml")
        self.config = doc

        declared = doc.get("zone")
        if declared != self.name:
            self.error(
                path,
                f"zone: {declared!r} but the directory is {self.name!r} -- the directory is "
                f"the zone, so make the field agree with it or move the directory",
            )
        dnssec = doc.get("dnssec", "unsigned")
        if dnssec not in {"signed", "unsigned"}:
            self.error(path, f"dnssec: {dnssec!r} must be 'signed' or 'unsigned'")

    @property
    def ttl_default(self) -> int:
        return int((self.config.get("ttl") or {}).get("default", 1))

    @property
    def ttl_validation(self) -> int:
        ttl = self.config.get("ttl") or {}
        return int(ttl.get("validation", ttl.get("default", 1)))

    def _load_services(self) -> None:
        services_dir = self.dir / "services"
        if not services_dir.is_dir():
            return
        for child in sorted(p for p in services_dir.iterdir() if p.is_dir()):
            svc_path = child / "service.yaml"
            rec_path = child / "records.yaml"
            has_records = rec_path.is_file()

            if not svc_path.is_file():
                self.error(
                    self.rel(child),
                    "no service.yaml -- a directory under services/ without one is a namespace "
                    "with no owner and no expiry date",
                )
                continue

            doc = self._load(svc_path) or {}
            if not isinstance(doc, dict):
                self.error(svc_path, "must be a mapping")
                continue
            self._check_keys(svc_path, doc, SERVICE_KEYS, "service.yaml")

            if "." in child.name:
                self.error(
                    self.rel(child),
                    f"a service directory is one label -- {child.name!r} nests a namespace "
                    f"inside another one, and the path alone cannot prevent that",
                )
            if not doc.get("owner"):
                self.error(svc_path, "owner is required -- a namespace with no owning team has nobody to ask")

            delegation = doc.get("delegation")
            if delegation is not None:
                if not isinstance(delegation, dict):
                    self.error(svc_path, "delegation must be a mapping or null")
                    delegation = None
                else:
                    self._check_keys(svc_path, delegation, DELEGATION_KEYS, "delegation")
                    if delegation.get("type") != "external":
                        self.error(
                            svc_path,
                            f"delegation.type must be 'external' (got {delegation.get('type')!r})",
                        )
                    if not delegation.get("nameservers"):
                        self.error(svc_path, "delegation.nameservers is required")
                    if not delegation.get("expires"):
                        self.error(
                            svc_path,
                            "an external delegation must set expires -- a subdomain takeover is a "
                            "delegation that outlived the service it pointed at",
                        )

            self.services.append({
                "path": self.rel(child),
                "zone": self.name,
                "dir": child.name,
                "fqdn": f"{child.name}.{self.name}",
                "owner": doc.get("owner"),
                "expires": _jsonable(doc.get("expires")),
                "delegation": _jsonable(delegation),
                "delegated": bool(delegation and delegation.get("type") == "external"),
                "has_records_file": has_records,
            })

            if delegation and delegation.get("type") == "external" and has_records:
                self.error(
                    self.rel(rec_path),
                    "this namespace is delegated externally, so nothing here is ever answered from "
                    "this zone -- delegate the namespace or hold it here, not both",
                )

    def _records_from(self, path: Path, prefix: str, allowed_types: set[str] | None,
                      single_label_names: bool) -> None:
        """Read a `records:` file and render it.

        prefix is what a relative name is joined onto; "" means the zone apex.
        """
        doc = self._load(path)
        if doc is None:
            return
        if not isinstance(doc, dict):
            self.error(path, "must be a mapping with a `records:` key")
            return
        self._check_keys(path, doc, {"records"}, "a records file")
        entries = doc.get("records")
        if entries is None:
            entries = []
        if not isinstance(entries, list):
            self.error(path, "records: must be a list")
            return

        rendered: list[dict] = []
        for index, entry in enumerate(entries):
            where = f"records[{index}]"
            if not isinstance(entry, dict):
                self.error(path, f"{where}: must be a mapping")
                continue
            self._check_keys(path, entry, RECORD_KEYS, where)

            name = entry.get("name")
            rtype = entry.get("type")
            values = entry.get("values")

            if not isinstance(name, str) or not name:
                self.error(path, f"{where}: name is required")
                continue
            if not isinstance(rtype, str) or not rtype:
                self.error(path, f"{where}: type is required")
                continue
            rtype = rtype.upper()
            if not isinstance(values, list) or not values:
                self.error(path, f"{where}: values must be a non-empty list")
                continue

            if rtype not in CLOUDFLARE_RECORD_TYPES:
                self.error(path, f"{where}: {rtype} is not a DNS record type Cloudflare accepts")
                continue
            if allowed_types is not None and rtype not in allowed_types:
                self.error(
                    path,
                    f"{where}: {rtype} is not permitted here -- a team's own records are "
                    f"{', '.join(sorted(allowed_types))}, and delegation is declared in service.yaml",
                )
                continue

            # A dotted name is how a record leaves the namespace it was written
            # in. TXT is the one exception: DKIM selectors and _smtp._tls need a
            # dot, and inside a service namespace a dotted TXT is still inside it.
            if single_label_names and name != "@" and "." in name and rtype != "TXT":
                self.error(
                    path,
                    f"{where}: name {name!r} must be a single label -- a dot nests a namespace "
                    f"that nothing in this repository owns",
                )
                continue

            proxied = bool(entry.get("proxied", False))
            if proxied and rtype not in {"A", "AAAA", "CNAME"}:
                self.error(path, f"{where}: a {rtype} record cannot be proxied")
                continue
            if proxied and "ttl" in entry and entry["ttl"] != 1:
                self.error(
                    path,
                    f"{where}: ttl {entry['ttl']} conflicts with proxied: true -- Cloudflare serves "
                    f"a proxied record and controls its TTL, so leave ttl out",
                )
                continue
            if rtype in {"MX", "SRV", "URI"} and entry.get("priority") is None:
                self.error(path, f"{where}: a {rtype} record needs priority")
                continue

            # prefix is "" at the apex and "<service>." inside a service, so a
            # name is joined onto the namespace rather than onto the zone. There
            # is no fully qualified form, which is what keeps a team's records
            # inside its own namespace without anything having to check.
            base = f"{prefix}{self.name}" if prefix else self.name
            fqdn = base if name == "@" else f"{name}.{base}"

            ttl = 1 if proxied else int(entry.get("ttl", self.ttl_default))
            for value in values:
                if not isinstance(value, str):
                    self.error(path, f"{where}: every value must be a string (got {value!r})")
                    continue
                self.records.append(Record(
                    zone=self.name, source=self.rel(path), name=fqdn.lower(), type=rtype,
                    content=_normalise(rtype, value), ttl=ttl, proxied=proxied,
                    priority=entry.get("priority"),
                ))
            rendered.append(_jsonable(entry) | {"type": rtype})

        self.files.append({"path": self.rel(path), "zone": self.name, "records": rendered})

    def _load_apex(self) -> None:
        apex_dir = self.dir / "apex"
        if not apex_dir.is_dir():
            return
        for path in sorted(apex_dir.glob("*.yaml")):
            # No type allowlist and no single-label rule: apex/ is owned by the
            # critical approvers and is where a record type this design did not
            # foresee is allowed to live. DKIM selectors are dotted CNAMEs.
            self._records_from(path, prefix="", allowed_types=None, single_label_names=False)

    def _load_service_records(self) -> None:
        services_dir = self.dir / "services"
        if not services_dir.is_dir():
            return
        for child in sorted(p for p in services_dir.iterdir() if p.is_dir()):
            path = child / "records.yaml"
            if not path.is_file():
                continue
            self._records_from(
                path, prefix=f"{child.name}.",
                allowed_types=SERVICE_RECORD_TYPES, single_label_names=True,
            )

    def _load_validations(self) -> None:
        validations_dir = self.dir / "validations"
        if not validations_dir.is_dir():
            return
        for path in sorted(validations_dir.glob("*.yaml")):
            doc = self._load(path)
            if doc is None:
                continue
            if not isinstance(doc, dict):
                self.error(path, "must be a mapping")
                continue
            self._check_keys(path, doc, VALIDATION_KEYS, "a validation file")

            for field_name in ("vendor", "purpose", "expires"):
                if not doc.get(field_name):
                    self.error(
                        path,
                        f"{field_name} is required -- a record nobody can explain is a record "
                        f"nobody will ever dare to delete",
                    )

            txt = doc.get("txt") or {}
            cname = doc.get("cname") or {}
            if not isinstance(txt, dict):
                self.error(path, "txt: must be a mapping of name to a list of strings")
                txt = {}
            if not isinstance(cname, dict):
                self.error(path, "cname: must be a mapping of name to one target")
                cname = {}
            if not txt and not cname:
                self.error(path, "declares no txt and no cname records")

            for name, values in txt.items():
                if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                    self.error(path, f"txt {name!r}: must be a list of strings")
                    continue
                fqdn = self.name if name == "@" else f"{name}.{self.name}"
                for value in values:
                    self.records.append(Record(
                        zone=self.name, source=self.rel(path), name=fqdn.lower(), type="TXT",
                        content=value, ttl=self.ttl_validation, proxied=False, priority=None,
                    ))

            for name, target in cname.items():
                if name == "@":
                    self.error(
                        path,
                        "a CNAME at the apex replaces the website, whatever the vendor's "
                        "instructions say -- a TXT record at @ is the correct way to prove a domain",
                    )
                    continue
                if "." in name:
                    self.error(
                        path,
                        f"cname {name!r} must be a single label -- a dotted name lands inside a "
                        f"service namespace, and a CNAME is exclusive at its name, so it would not "
                        f"clash with that team's records, it would invalidate them",
                    )
                    continue
                if not isinstance(target, str):
                    self.error(path, f"cname {name!r}: one name, one target (got {target!r})")
                    continue
                self.records.append(Record(
                    zone=self.name, source=self.rel(path), name=f"{name}.{self.name}".lower(),
                    type="CNAME", content=_normalise("CNAME", target), ttl=self.ttl_validation,
                    proxied=False, priority=None,
                ))

            self.validations.append({
                "path": self.rel(path), "zone": self.name,
                "vendor": doc.get("vendor"), "requested_by": doc.get("requested_by"),
                "purpose": doc.get("purpose"), "expires": _jsonable(doc.get("expires")),
                "txt": _jsonable(txt), "cname": _jsonable(cname),
            })

    def _load_delegations(self) -> None:
        for svc in self.services:
            if not svc["delegated"]:
                continue
            for nameserver in svc["delegation"].get("nameservers") or []:
                if not isinstance(nameserver, str):
                    self.error(f"{svc['path']}/service.yaml", f"nameserver {nameserver!r} must be a string")
                    continue
                self.records.append(Record(
                    zone=self.name, source=f"{svc['path']}/service.yaml", name=svc["fqdn"].lower(),
                    type="NS", content=_normalise("NS", nameserver), ttl=self.ttl_default,
                    proxied=False, priority=None,
                ))


def _normalise(rtype: str, value: str) -> str:
    """A value as written in this repository, in the form the provider stores."""
    return value.rstrip(".") if rtype.upper() in HOSTNAME_TYPES else value


def _api_content(rtype: str, value: str) -> str:
    """A value as the Cloudflare REST API returns it, in the same form.

    The API hands back TXT content as it appears in the zone file -- quoted, and
    split into 255-byte chunks once it is long enough, as a DKIM key always is:

        "\"v=spf1 include:icloud.com ~all\""
        "\"v=DKIM1; k=rsa; p=MIIBIj...\" \"...rest of the key\""

    The Terraform provider stores the value itself, so a comparison against the
    API has to undo this. Concatenating the chunks is not a convenience: a TXT
    record's value *is* the concatenation of its strings, and splitting it is a
    transport detail of the wire format.
    """
    if rtype.upper() != "TXT":
        return _normalise(rtype, value)
    if not (value.startswith('"') and value.endswith('"')):
        return value

    out, in_string, escaped = [], False, False
    for char in value:
        if escaped:
            out.append(char)
            escaped = False
        elif char == "\\" and in_string:
            escaped = True
        elif char == '"':
            in_string = not in_string
        elif in_string:
            out.append(char)
        elif not char.isspace():
            # Not a well-formed sequence of quoted strings after all; the record
            # is stranger than this function is, so do not guess at it.
            return value
    return "".join(out)


# --------------------------------------------------------------------------
# checks that need the whole zone
# --------------------------------------------------------------------------

def check_zone_wide(zone: Zone, today: dt.date, expiry_warning_days: int) -> None:
    """Rules about the finished record set rather than about one file."""

    by_key: dict[str, list[Record]] = {}
    by_name: dict[str, list[Record]] = {}
    for record in zone.records:
        by_key.setdefault(record.key, []).append(record)
        by_name.setdefault(record.name, []).append(record)

    # The same record written twice. Terraform would refuse to build its map,
    # but it should not be Terraform that explains it.
    for key, group in sorted(by_key.items()):
        if len(group) > 1:
            sources = ", ".join(sorted({r.source for r in group}))
            zone.error(sources, f"{key.replace('|', ' ')} is declared more than once ({sources})")

    # A CNAME is exclusive at its name. Anything else at the same name is
    # unreachable, and resolvers are entitled to treat the zone as broken.
    for name, group in sorted(by_name.items()):
        types = {r.type for r in group}
        if "CNAME" in types and types != {"CNAME"}:
            others = ", ".join(sorted(types - {"CNAME"}))
            sources = ", ".join(sorted({r.source for r in group}))
            zone.error(sources, f"{name} has a CNAME and also {others} -- a CNAME is exclusive at its name")
        cnames = [r for r in group if r.type == "CNAME"]
        if len(cnames) > 1:
            sources = ", ".join(sorted({r.source for r in cnames}))
            zone.error(sources, f"{name} has {len(cnames)} CNAME records -- one name, one target")

    # Below a delegation, resolvers follow the NS records and never read
    # anything else this zone publishes there. A record written below a zone cut
    # is not wrong, it is invisible, which is worse: it looks maintained.
    for svc in zone.services:
        if not svc["delegated"]:
            continue
        cut = svc["fqdn"].lower()
        for record in zone.records:
            if record.type == "NS" and record.name == cut:
                continue
            if record.name == cut or record.name.endswith(f".{cut}"):
                zone.error(
                    record.source,
                    f"{record.name} {record.type} sits at or below the {cut} delegation, so it is "
                    f"never answered from this zone -- it belongs in the delegated zone",
                )

    # A TXT record may be dotted, but it must not walk into a namespace whose
    # owning team will never see the change.
    service_dirs = {svc["dir"]: svc for svc in zone.services}
    for validation in zone.validations:
        for name in validation["txt"]:
            if name == "@":
                continue
            tail = name.split(".")[-1]
            if tail in service_dirs:
                zone.error(
                    validation["path"],
                    f"TXT {name!r} sits inside the {tail!r} service namespace, and that team will "
                    f"not see this change -- ask them to add it to their records.yaml",
                )

    # Expiry dates. A date that has passed is a warning and not an error: the
    # point of the date is to make somebody look, and blocking every DNS change
    # in the repository because a HubSpot record turned two years old would
    # teach people to set the date far away.
    soon = today + dt.timedelta(days=expiry_warning_days)

    def check_expiry(path: str, value: Any, what: str) -> None:
        if value is None:
            return
        try:
            expires = dt.date.fromisoformat(str(value))
        except ValueError:
            zone.error(path, f"{what} expires: {value!r} is not a date (use YYYY-MM-DD)")
            return
        if expires < today:
            zone.warn(path, f"{what} expired on {expires} -- confirm it is still wanted or remove it")
        elif expires <= soon:
            zone.warn(path, f"{what} expires on {expires}")

    for validation in zone.validations:
        check_expiry(validation["path"], validation["expires"], f"the {validation['vendor']} validation")
    for svc in zone.services:
        check_expiry(f"{svc['path']}/service.yaml", svc["expires"], f"the {svc['fqdn']} allocation")
        if svc["delegated"]:
            check_expiry(
                f"{svc['path']}/service.yaml",
                (svc["delegation"] or {}).get("expires"),
                f"the {svc['fqdn']} delegation",
            )


# --------------------------------------------------------------------------
# CODEOWNERS
# --------------------------------------------------------------------------

def parse_codeowners(root: Path) -> list[tuple[str, list[str]]]:
    for candidate in (root / ".github/CODEOWNERS", root / "CODEOWNERS", root / "docs/CODEOWNERS"):
        if candidate.is_file():
            rules: list[tuple[str, list[str]]] = []
            for line in candidate.read_text(encoding="utf-8").splitlines():
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                pattern, *owners = line.split()
                if owners:
                    rules.append((pattern, owners))
            return rules
    return []


def codeowners_for(rules: list[tuple[str, list[str]]], path: str) -> list[str]:
    """GitHub applies the last pattern that matches, not the most specific one."""
    owners: list[str] = []
    for pattern, rule_owners in rules:
        if _codeowners_match(pattern, path):
            owners = rule_owners
    return owners


def _codeowners_match(pattern: str, path: str) -> bool:
    if pattern == "*":
        return True
    anchored = pattern.startswith("/")
    body = pattern.lstrip("/")
    if body.endswith("/"):
        body += "**"
    candidates = [path] if anchored else [path, *(path.split("/", i)[-1] for i in range(1, path.count("/") + 1))]
    return any(fnmatch.fnmatchcase(candidate, body) for candidate in candidates)


def _same_team(a: str | None, b: str) -> bool:
    """`platform-engineering` and `@example/platform-engineering` are the same team."""
    def slug(value: str) -> str:
        return value.lstrip("@").split("/")[-1].lower()
    return a is not None and slug(a) == slug(b)


def check_codeowners(root: Path, zones: list[Zone]) -> list[Finding]:
    """Two places declare who owns a service. They must not disagree.

    CODEOWNERS decides who may approve a change to records.yaml. service.yaml
    decides which team policy holds accountable for the namespace. If they
    differ, one team reviews the file and a different team answers for it.
    """
    rules = parse_codeowners(root)
    findings: list[Finding] = []
    if not rules:
        return [Finding("warning", ".github/CODEOWNERS", "not found -- nothing constrains who may approve a change")]

    for zone in zones:
        for svc in zone.services:
            records_path = f"{svc['path']}/records.yaml"
            owners = codeowners_for(rules, records_path)
            declared = svc["owner"]

            if not svc["has_records_file"]:
                if any(_codeowners_match(pattern, records_path) and "/services/" in pattern for pattern, _ in rules):
                    findings.append(Finding(
                        "warning", ".github/CODEOWNERS",
                        f"{records_path} has a CODEOWNERS line but no such file -- remove the line "
                        f"when the service is delegated or removed",
                    ))
                continue

            if not owners:
                findings.append(Finding(
                    "error", ".github/CODEOWNERS",
                    f"no line matches {records_path}, so the default owner reviews it and the "
                    f"{svc['fqdn']} team cannot merge its own records",
                ))
            elif not any(_same_team(declared, owner) for owner in owners):
                findings.append(Finding(
                    "error", f"{svc['path']}/service.yaml",
                    f"owner is {declared!r} but CODEOWNERS sends {records_path} to "
                    f"{' '.join(owners)} -- one team would review the file and another would "
                    f"answer for it",
                ))
    return findings


# --------------------------------------------------------------------------
# the tree
# --------------------------------------------------------------------------

def discover(root: Path, zones_dir: Path, only: str | None) -> list[Zone]:
    if not zones_dir.is_dir():
        sys.exit(f"dnsctl: no zones directory at {zones_dir}")
    directories = sorted(p for p in zones_dir.iterdir() if p.is_dir() and not p.name.startswith("."))
    if only:
        directories = [p for p in directories if p.name == only]
        if not directories:
            sys.exit(f"dnsctl: no zone directory named {only!r} under {zones_dir}")
    zones = []
    for directory in directories:
        zone = Zone(root, directory)
        zone.load()
        zones.append(zone)
    return zones


def collect(root: Path, zones_dir: Path, only: str | None, today: dt.date,
            expiry_warning_days: int, codeowners: bool = True) -> tuple[list[Zone], list[Finding]]:
    zones = discover(root, zones_dir, only)
    for zone in zones:
        check_zone_wide(zone, today, expiry_warning_days)
    findings = [f for zone in zones for f in zone.findings]
    if codeowners:
        findings += check_codeowners(root, zones)
    return zones, findings


def policy_input(zones: list[Zone], today: dt.date) -> dict:
    return {
        "today": today.isoformat(),
        "zones": [
            {
                "zone": z.name,
                "path": z.rel(z.dir),
                "dnssec": z.config.get("dnssec", "unsigned"),
                "nameservers": z.config.get("nameservers") or [],
            }
            for z in zones
        ],
        "services": [s for z in zones for s in z.services],
        "validations": [v for z in zones for v in z.validations],
        "files": [f for z in zones for f in z.files],
        "records": [r.as_dict() for z in zones for r in sorted(z.records, key=lambda r: r.key)],
    }


# --------------------------------------------------------------------------
# live lookups
# --------------------------------------------------------------------------

def _get_json(url: str, headers: dict[str, str] | None = None) -> Any:
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def resolve(name: str, rtype: str) -> list[str]:
    """One DNS answer, over HTTPS, from a resolver that is not the zone's host."""
    query = urllib.parse.urlencode({"name": name, "type": rtype})
    for endpoint, headers in (
        (f"https://dns.google/resolve?{query}", {}),
        (f"https://cloudflare-dns.com/dns-query?{query}", {"Accept": "application/dns-json"}),
    ):
        try:
            payload = _get_json(endpoint, headers)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            continue
        return [a["data"] for a in payload.get("Answer", []) if a.get("type") == _rtype_number(rtype)]
    sys.exit(f"dnsctl: could not reach a DNS-over-HTTPS resolver to look up {rtype} {name}")


_RTYPE_NUMBERS = {"A": 1, "NS": 2, "CNAME": 5, "MX": 15, "TXT": 16, "AAAA": 28, "DS": 43, "CAA": 257}


def _rtype_number(rtype: str) -> int:
    return _RTYPE_NUMBERS[rtype.upper()]


CLOUDFLARE_API = "https://api.cloudflare.com/client/v4"


def cloudflare_get(path: str, token: str, params: dict[str, str] | None = None) -> Any:
    url = f"{CLOUDFLARE_API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    try:
        payload = _get_json(url, {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    except urllib.error.HTTPError as exc:
        sys.exit(f"dnsctl: Cloudflare API {exc.code} for {path}: {exc.read().decode(errors='replace')[:400]}")
    except urllib.error.URLError as exc:
        sys.exit(f"dnsctl: cannot reach the Cloudflare API: {exc}")
    if not payload.get("success", False):
        sys.exit(f"dnsctl: Cloudflare API refused {path}: {json.dumps(payload.get('errors'))}")
    return payload


def resolve_zone_id(zone: Zone, token: str) -> str:
    zone_id = zone.config.get("zone_id")
    if zone_id:
        return zone_id
    params = {"name": zone.name}
    if zone.config.get("account_id"):
        params["account.id"] = zone.config["account_id"]
    found = cloudflare_get("/zones", token, params)["result"]
    if not found:
        sys.exit(f"dnsctl: this token cannot see a Cloudflare zone named {zone.name}")
    if len(found) > 1:
        sys.exit(f"dnsctl: {len(found)} zones are named {zone.name}; set zone_id in zone.yaml")
    return found[0]["id"]


def live_records(zone: Zone, token: str) -> tuple[str, list[dict]]:
    """The zone id, and every record Cloudflare holds in it.

    The id comes back too because the records do not carry it: a record's
    Terraform import id is "<zone id>/<record id>", and only half of that is in
    the record.
    """
    zone_id = resolve_zone_id(zone, token)
    records, page = [], 1
    while True:
        payload = cloudflare_get(f"/zones/{zone_id}/dns_records", token, {"per_page": "100", "page": str(page)})
        records.extend(payload["result"])
        info = payload.get("result_info") or {}
        if page >= int(info.get("total_pages", 1)):
            return zone_id, records
        page += 1


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def report(findings: Iterable[Finding]) -> int:
    findings = sorted(findings, key=lambda f: (f.level != "error", f.path, f.message))
    errors = sum(1 for f in findings if f.level == "error")
    warnings = len(list(findings)) - errors
    for finding in findings:
        print(finding, file=sys.stderr if finding.level == "error" else sys.stdout)
    if errors:
        print(f"\n{errors} error(s), {warnings} warning(s)", file=sys.stderr)
        return 1
    print(f"ok -- 0 errors, {warnings} warning(s)")
    return 0


def cmd_validate(args, root: Path) -> int:
    _, findings = collect(root, args.zones, args.zone, args.today, args.expiry_warning_days,
                              codeowners=not args.no_codeowners)
    return report(findings)


def cmd_build(args, root: Path) -> int:
    zones, findings = collect(root, args.zones, args.zone, args.today, args.expiry_warning_days,
                              codeowners=not args.no_codeowners)
    if any(f.level == "error" for f in findings) and not args.force:
        report(findings)
        print("dnsctl: refusing to build a policy document from a tree that does not parse", file=sys.stderr)
        return 1
    document = json.dumps(policy_input(zones, args.today), indent=2, sort_keys=True)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(document + "\n", encoding="utf-8")
        print(f"wrote {args.out}")
    else:
        print(document)
    return 0


def cmd_render(args, root: Path) -> int:
    zones, findings = collect(root, args.zones, args.zone, args.today, args.expiry_warning_days,
                              codeowners=not args.no_codeowners)
    if any(f.level == "error" for f in findings) and not args.force:
        return report(findings)
    records = sorted((r for z in zones for r in z.records), key=lambda r: (r.zone, r.name, r.type, r.content))
    if args.keys:
        for record in records:
            print(record.key)
    elif args.json:
        print(json.dumps([r.as_dict() for r in records], indent=2))
    else:
        width = max((len(r.name) for r in records), default=0)
        for record in records:
            flags = " proxied" if record.proxied else ""
            priority = f" {record.priority}" if record.priority is not None else ""
            print(f"{record.name:<{width}}  {record.type:<5} ttl={record.ttl:<6}{flags:<8}{priority} {record.content}"
                  f"    <- {record.source}")
    return 0


def cmd_verify(args, root: Path) -> int:
    """Ask the public DNS whether zone.yaml is still telling the truth."""
    zones = discover(root, args.zones, args.zone)
    findings: list[Finding] = []
    for zone in zones:
        path = f"{zone.rel(zone.dir)}/zone.yaml"

        declared = sorted(n.lower().rstrip(".") for n in (zone.config.get("nameservers") or []))
        if declared:
            live = sorted(n.lower().rstrip(".") for n in resolve(zone.name, "NS"))
            if live != declared:
                findings.append(Finding(
                    "error", path,
                    f"nameservers: {', '.join(declared)} but the registrar delegates to "
                    f"{', '.join(live) or '(nothing)'}",
                ))
            else:
                print(f"ok    {zone.name} NS  {', '.join(live)}")
        else:
            findings.append(Finding("warning", path, "no nameservers listed, so the delegation is unchecked"))

        ds = resolve(zone.name, "DS")
        observed = "signed" if ds else "unsigned"
        stated = zone.config.get("dnssec", "unsigned")
        if observed != stated:
            findings.append(Finding(
                "error", path,
                f"dnssec: {stated} but the registrar publishes {'a DS record' if ds else 'no DS record'}. "
                + ("Remove the DS record and wait for its TTL before changing nameservers, or the "
                   "whole domain goes bogus." if ds else "If the zone was just signed, add the DS "
                   "record at the registrar and set dnssec: signed."),
            ))
        else:
            print(f"ok    {zone.name} DNSSEC {observed}")
    return report(findings) if findings else 0


def cmd_drift(args, root: Path) -> int:
    """What Cloudflare holds that this repository does not, and the other way round."""
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not token:
        sys.exit("dnsctl: set CLOUDFLARE_API_TOKEN (Zone:DNS:Read is enough for drift)")

    zones, findings = collect(root, args.zones, args.zone, args.today, args.expiry_warning_days,
                              codeowners=not args.no_codeowners)
    if any(f.level == "error" for f in findings):
        return report(findings)

    differences = 0
    for zone in zones:
        wanted = {r.key: r for r in zone.records}
        live: dict[str, dict] = {}
        _, live_list = live_records(zone, token)
        for record in live_list:
            rtype = record["type"].upper()
            content = _api_content(rtype, record.get("content") or "")
            live[f"{record['name'].lower()}|{rtype}|{content}"] = record

        unmanaged = sorted(set(live) - set(wanted))
        missing = sorted(set(wanted) - set(live))

        print(f"\n{zone.name}: {len(wanted)} in this repository, {len(live)} in Cloudflare")

        for key in unmanaged:
            record = live[key]
            note = ""
            for svc in zone.services:
                cut = svc["fqdn"].lower()
                if svc["delegated"] and (record["name"].lower() == cut or record["name"].lower().endswith(f".{cut}")):
                    note = f"  (below the {cut} delegation, so Cloudflare never answers with it)"
            print(f"  only in Cloudflare  {key.replace('|', ' ')}{note}")
        for key in missing:
            print(f"  only in this repo   {key.replace('|', ' ')}  <- {wanted[key].source}")

        for key in sorted(set(wanted) & set(live)):
            want, have = wanted[key], live[key]
            for label, mine, theirs in (
                ("ttl", want.ttl, int(have.get("ttl", 0))),
                ("proxied", want.proxied, bool(have.get("proxied", False))),
                ("priority", want.priority, have.get("priority")),
            ):
                if label == "priority" and mine is None:
                    continue
                if mine != theirs:
                    print(f"  differs             {key.replace('|', ' ')}: {label} {theirs!r} -> {mine!r}")
                    differences += 1

        differences += len(unmanaged) + len(missing)

    if differences:
        print(f"\n{differences} difference(s). `only in this repo` disappears on the next apply; "
              f"`only in Cloudflare` will not -- Terraform does not delete what it was never told about.")
    else:
        print("\nno differences")
    return 1 if (differences and args.strict) else 0


def cmd_import_blocks(args, root: Path) -> int:
    """Write the import blocks that adopt a zone Cloudflare already serves.

    Terraform keys each record by name, type and value, so the address of a
    record is the record. The Cloudflare id is not: it is a random string that
    nobody can check by reading. This pairs them up once, so that adopting a
    zone is a plan that changes nothing rather than a plan that recreates
    everything.
    """
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not token:
        sys.exit("dnsctl: set CLOUDFLARE_API_TOKEN (Zone:DNS:Read is enough)")

    zones, findings = collect(root, args.zones, args.zone, args.today, args.expiry_warning_days,
                              codeowners=not args.no_codeowners)
    if any(f.level == "error" for f in findings):
        return report(findings)

    lines = [
        "# Generated by `dnsctl import-blocks`. Adopts the records Cloudflare",
        "# already serves, so that the first apply changes no DNS data.",
        "#",
        "# Keyed by zone and selected with var.zone, because the root module owns",
        "# one zone at a time. An import block naming another zone's records would",
        "# be active while planning this one.",
        "#",
        "# One `import` block with for_each, rather than one block per record.",
        "# Repeated blocks targeting instances of the same resource inside a module",
        "# were observed to apply only the first and silently ignore the rest:",
        "# fifteen blocks produced `1 to import, 14 to add`, which would have",
        "# duplicated the whole zone. The for_each form produced `15 to import,",
        "# 0 to add`. Verified against Terraform 1.16.0.",
        "#",
        "# Generated: a list of Cloudflare record ids. Commit it for the apply that",
        "# adopts a zone, because CI has only what is in the repository, then delete",
        "# it. Regenerate rather than keep -- it goes stale the moment a record is",
        "# recreated by hand.",
        "",
        "locals {",
        "  imports = {",
    ]
    total, unmatched = 0, []

    for zone in zones:
        wanted = {r.key: r for r in zone.records}
        live: dict[str, dict] = {}
        zone_id, live_list = live_records(zone, token)
        for record in live_list:
            rtype = record["type"].upper()
            content = _api_content(rtype, record.get("content") or "")
            live[f"{record['name'].lower()}|{rtype}|{content}"] = record

        pairs = []
        for key in sorted(wanted):
            if key not in live:
                unmatched.append(f"{zone.name}: {key.replace('|', ' ')}")
                continue
            pairs.append((key, f"{zone_id}/{live[key]['id']}"))
            total += 1

        if not pairs:
            continue

        lines.append(f'    "{_hcl(zone.name)}" = {{')
        width = max(len(_hcl(key)) for key, _ in pairs) + 2
        lines += [f'      {f'"{_hcl(key)}"':<{width}} = "{ident}"' for key, ident in pairs]
        lines.append("    }")

    lines += ["  }", "}", "", "import {",
              "  for_each = try(local.imports[var.zone], {})",
              "  to       = module.zone.cloudflare_dns_record.this[each.key]",
              "  id       = each.value", "}"]

    document = "\n".join(lines).rstrip() + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(document, encoding="utf-8")
        print(f"wrote {args.out}: {total} record(s) to adopt")
    else:
        print(document)

    for line in unmatched:
        print(f"will be created rather than adopted: {line}", file=sys.stderr)
    return 0


def _hcl(value: str) -> str:
    """Escape for an HCL quoted string. ${ starts an interpolation, so double the $."""
    return (value.replace("\\", "\\\\").replace('"', '\\"')
            .replace("${", "$${").replace("%{", "%%{"))


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parent.parent

    # Options that make sense for every subcommand are declared on a parent
    # parser and attached to both sides, so `dnsctl --zone x render` and
    # `dnsctl render --zone x` both work. SUPPRESS is what makes that safe: an
    # option the subparser did not see is left alone rather than reset to its
    # default, which would silently discard the one given before the subcommand.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--zones", type=Path, default=argparse.SUPPRESS,
                        help="the zones directory")
    common.add_argument("--zone", default=argparse.SUPPRESS,
                        help="limit to one zone directory")
    common.add_argument("--today", type=dt.date.fromisoformat, default=argparse.SUPPRESS,
                        help="the date expiry checks are made against (YYYY-MM-DD)")
    common.add_argument("--expiry-warning-days", type=int, default=argparse.SUPPRESS,
                        help="warn this many days before an expiry date")
    common.add_argument("--no-codeowners", action="store_true", default=argparse.SUPPRESS,
                        help="skip the CODEOWNERS cross-check (used by the fixture tests, "
                             "which have no CODEOWNERS of their own)")

    parser = argparse.ArgumentParser(prog="dnsctl", description=__doc__, parents=[common],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.set_defaults(zones=root / "zones", zone=None, today=dt.date.today(),  # noqa: DTZ011
                        expiry_warning_days=60, no_codeowners=False)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("validate", parents=[common],
                   help="check the tree; exit non-zero on any error")

    build = sub.add_parser("build", parents=[common],
                           help="write the document policy/*.rego is evaluated against")
    build.add_argument("--out", type=Path, help="write here instead of stdout")
    build.add_argument("--force", action="store_true", help="build even if the tree has errors")

    render = sub.add_parser("render", parents=[common],
                            help="print every record the tree produces")
    render.add_argument("--keys", action="store_true", help="print only \"<name>|<TYPE>|<content>\"")
    render.add_argument("--json", action="store_true", help="print JSON")
    render.add_argument("--force", action="store_true", help="render even if the tree has errors")

    sub.add_parser("verify", parents=[common],
                   help="ask the public DNS whether zone.yaml is still true")

    drift = sub.add_parser("drift", parents=[common],
                           help="compare Cloudflare with this repository")
    drift.add_argument("--strict", action="store_true", help="exit non-zero when anything differs")

    adopt = sub.add_parser("import-blocks", parents=[common],
                           help="write the Terraform import blocks that adopt an existing zone")
    adopt.add_argument("--out", type=Path, help="write here instead of stdout")

    args = parser.parse_args(argv)
    args.zones = args.zones.resolve()

    return {
        "validate": cmd_validate, "build": cmd_build, "render": cmd_render,
        "verify": cmd_verify, "drift": cmd_drift, "import-blocks": cmd_import_blocks,
    }[args.command](args, root)


if __name__ == "__main__":
    sys.exit(main())
