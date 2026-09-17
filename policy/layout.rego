# Where a record goes is decided by CODEOWNERS. What a record may be is decided
# here.
#
# CODEOWNERS matches paths, and a team with write access to its own records.yaml
# can write anything in that file. Every such change touches only a path the
# team legitimately owns, so no rule about paths can see the problem.
#
# The document this is evaluated against is written by `dnsctl build`, which
# derives every namespace from the directory it found the file in. Nothing here
# reads a namespace out of a file, because no file declares one.

package dns.layout

import rego.v1

# ---------------------------------------------------------------------------
# services
# ---------------------------------------------------------------------------

# A service is its directory. A directory such as `docs.search` makes a
# nested namespace, and the path alone cannot prevent that.
deny contains msg if {
	svc := input.services[_]
	contains(svc.dir, ".")
	msg := sprintf(
		"%s: a service directory is one label -- %q would nest inside another namespace",
		[svc.path, svc.dir],
	)
}

# Records a team writes for itself. An allowlist, not a denylist: a denylist of
# MX, NS and CAA permits every type nobody has thought about, and those are the
# dangerous ones. HTTPS and SVCB carry ALPN, port and ECH parameters that change
# how a browser connects. TLSA can stop inbound mail from every DANE sender. SRV
# moves service discovery to another host. An allowlist refuses all of them now,
# and refuses whatever Cloudflare adds next without having to be told about it.
deny contains msg if {
	f := input.files[_]
	regex.match(`^zones/[^/]+/services/[^/]+/records\.yaml$`, f.path)
	r := f.records[_]
	not r.type in {"A", "AAAA", "CNAME", "TXT"}
	msg := sprintf(
		"%s: %s is not permitted in a team's own records -- delegation is declared in service.yaml",
		[f.path, r.type],
	)
}

# A dotted name in a record file makes a namespace nobody owns. TXT is the
# exception: DKIM selectors and _smtp._tls need a dot, and a dotted TXT written
# in a service file is still inside that service's namespace.
deny contains msg if {
	f := input.files[_]
	regex.match(`^zones/[^/]+/services/[^/]+/records\.yaml$`, f.path)
	r := f.records[_]
	r.type != "TXT"
	r.name != "@"
	contains(r.name, ".")
	msg := sprintf(
		"%s: name %q must be a single label -- a dot nests a namespace nothing in this repository owns",
		[f.path, r.name],
	)
}

# Hold the namespace here, or delegate it. Not both. Below a delegation,
# resolvers follow the NS records and never read anything else this zone
# publishes there, so a records.yaml would be YAML that looks live and answers
# nothing. Putting the delegation in service.yaml rather than in a record list
# means a directory listing shows the conflict.
deny contains msg if {
	svc := input.services[_]
	svc.delegation.type == "external"
	svc.has_records_file
	msg := sprintf(
		"%s: delegated externally, so records.yaml would never be answered from this zone",
		[svc.path],
	)
}

# The same rule applied to the finished record set, which catches the case the
# directory listing cannot show: a record written in apex/ or validations/ that
# happens to land at or below somebody else's delegation.
deny contains msg if {
	svc := input.services[_]
	svc.delegated
	r := input.records[_]
	r.zone == svc.zone
	below_cut(r.name, svc.fqdn)
	not is_the_delegation(r, svc)
	msg := sprintf(
		"%s: %s %s sits at or below the %s delegation, so this zone never answers with it",
		[r.source, r.name, r.type, svc.fqdn],
	)
}

below_cut(name, cut) if name == cut

below_cut(name, cut) if endswith(name, concat("", [".", cut]))

is_the_delegation(r, svc) if {
	r.type == "NS"
	r.name == svc.fqdn
}

# A subdomain takeover is a delegation that stayed behind after its service
# ended. Every delegation gets a date at which somebody has to say it is still
# wanted.
deny contains msg if {
	svc := input.services[_]
	svc.delegation.type == "external"
	missing(svc.delegation, "expires")
	msg := sprintf("%s: an external delegation must set expires", [svc.path])
}

# ---------------------------------------------------------------------------
# validations
# ---------------------------------------------------------------------------
#
# A validation file has no `type` field, so an MX or NS record has nowhere to be
# written and needs no rule here. That is the same method as relative names:
# make the wrong thing impossible to write rather than catching it afterwards.
# Only the names need rules.

# A CNAME is exclusive at its name. A dotted name such as `docs.search` lands
# inside a team's namespace, so it would not merely clash with that team's
# records -- it would make them unreachable.
deny contains msg if {
	v := input.validations[_]
	some name, _ in v.cname
	contains(name, ".")
	msg := sprintf(
		"%s: CNAME %q must be a single label -- a dotted name lands inside a service namespace, and a CNAME is exclusive at its name",
		[v.path, name],
	)
}

deny contains msg if {
	v := input.validations[_]
	v.cname["@"]
	msg := sprintf(
		"%s: a CNAME at the apex replaces the website, whatever the vendor's instructions say -- a TXT record at @ is the correct way to prove a domain",
		[v.path],
	)
}

# Without an explanation and a date, nobody can safely delete the record. People
# do not remove what they cannot explain, so unexplained records survive for
# years. One file per vendor means removing HubSpot is `git rm hubspot.yaml`
# and not an archaeology exercise in the repository history.
deny contains msg if {
	v := input.validations[_]
	some field in ["vendor", "purpose", "expires"]
	missing(v, field)
	msg := sprintf("%s: %s is required -- an unexplained record can never safely be removed", [v.path, field])
}

# `not obj[field]` alone is not enough. In Rego only `false` and undefined are
# falsy, so a key that is present and null -- which is what `expires:` with
# nothing after it produces, and what any tool that fills in absent fields
# produces -- would satisfy neither `obj[field]` nor `not obj[field]`, and the
# rule would quietly never fire.
missing(obj, field) if not obj[field]

missing(obj, field) if obj[field] == null

missing(obj, field) if obj[field] == ""

# A TXT name may contain a dot. It must not walk into a namespace whose owning
# team would never see the change.
deny contains msg if {
	v := input.validations[_]
	some name, _ in v.txt
	svc := input.services[_]
	svc.zone == v.zone
	endswith(name, concat("", [".", svc.dir]))
	msg := sprintf("%s: TXT %q sits inside the %q service namespace", [v.path, name, svc.dir])
}

# ---------------------------------------------------------------------------
# the finished zone
# ---------------------------------------------------------------------------

# A CNAME is exclusive at its name: anything else there is unreachable, and a
# resolver is entitled to treat the zone as broken. Approval boundaries make
# this easy to write by accident, because the CNAME and the record it shadows
# are usually in different files owned by different people.
deny contains msg if {
	some name
	names_with_cname[name]
	other := {r.type | r := input.records[_]; r.name == name; r.type != "CNAME"}
	count(other) > 0
	msg := sprintf("%s: has a CNAME and also %v -- a CNAME is exclusive at its name", [name, other])
}

names_with_cname contains name if {
	r := input.records[_]
	r.type == "CNAME"
	name := r.name
}

# ---------------------------------------------------------------------------
# warnings
# ---------------------------------------------------------------------------
#
# An expiry date exists to make somebody look, not to stop the world. Blocking
# every DNS change in the repository because one validation record turned two
# years old teaches people to write dates far in the future.
#
# The is_string guards matter: a missing date is null, and null sorts below
# every string, so without them every service that omits an optional expiry
# would report as expired.

warn contains msg if {
	v := input.validations[_]
	is_string(v.expires)
	v.expires < input.today
	msg := sprintf("%s: the %s validation expired on %s -- confirm it is still wanted or remove it", [v.path, v.vendor, v.expires])
}

warn contains msg if {
	svc := input.services[_]
	is_string(svc.expires)
	svc.expires < input.today
	msg := sprintf("%s: the %s allocation expired on %s", [svc.path, svc.fqdn, svc.expires])
}

warn contains msg if {
	svc := input.services[_]
	is_string(svc.delegation.expires)
	svc.delegation.expires < input.today
	msg := sprintf("%s: the %s delegation expired on %s -- a delegation that outlives its service is how a subdomain takeover starts", [svc.path, svc.fqdn, svc.delegation.expires])
}
