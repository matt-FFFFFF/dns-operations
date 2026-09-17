# One test for each rule, and one test for each rule's opposite. A policy that
# is never seen to fire is a policy nobody knows is broken.

package dns.layout_test

import data.dns.layout
import rego.v1

# --- fixtures --------------------------------------------------------------

empty := {"today": "2026-09-17", "zones": [], "services": [], "validations": [], "files": [], "records": []}

service(overrides) := object.union(
	{
		"path": "zones/example.com/services/search",
		"zone": "example.com",
		"dir": "search",
		"fqdn": "search.example.com",
		"owner": "@example/search",
		"expires": "2028-01-01",
		"delegation": null,
		"delegated": false,
		"has_records_file": true,
	},
	overrides,
)

validation(overrides) := object.union(
	{
		"path": "zones/example.com/validations/hubspot.yaml",
		"zone": "example.com",
		"vendor": "hubspot",
		"requested_by": "marketing",
		"purpose": "Domain verification",
		"expires": "2027-03-01",
		"txt": {},
		"cname": {},
	},
	overrides,
)

record(overrides) := object.union(
	{
		"zone": "example.com",
		"source": "zones/example.com/apex/website.yaml",
		"name": "www.example.com",
		"type": "CNAME",
		"content": "example.pages.dev",
		"ttl": 1,
		"proxied": false,
		"priority": null,
	},
	overrides,
)

with_input(overrides) := object.union(empty, overrides)

# --- a tree that is fine ---------------------------------------------------

test_a_clean_tree_denies_nothing if {
	count(layout.deny) == 0 with input as with_input({
		"services": [service({})],
		"validations": [validation({"txt": {"@": ["hubspot-domain-verification=x"]}})],
		"files": [{
			"path": "zones/example.com/services/search/records.yaml",
			"zone": "example.com",
			"records": [{"name": "docs", "type": "CNAME", "values": ["docs.pages.dev"]}],
		}],
		"records": [record({})],
	})
}

# --- services --------------------------------------------------------------

test_service_directory_must_be_one_label if {
	count(layout.deny) == 1 with input as with_input({"services": [service({"dir": "docs.search"})]})
}

test_service_records_use_an_allowlist if {
	count(layout.deny) == 1 with input as with_input({"files": [{
		"path": "zones/example.com/services/search/records.yaml",
		"zone": "example.com",
		"records": [{"name": "mail", "type": "MX", "values": ["mx.example.net"], "priority": 10}],
	}]})
}

test_the_allowlist_refuses_types_nobody_listed if {
	# HTTPS carries ALPN, port and ECH parameters. A denylist of MX, NS and CAA
	# would have let it through.
	count(layout.deny) == 1 with input as with_input({"files": [{
		"path": "zones/example.com/services/search/records.yaml",
		"zone": "example.com",
		"records": [{"name": "www", "type": "HTTPS", "values": ["1 . alpn=h2"]}],
	}]})
}

test_service_record_names_are_one_label if {
	count(layout.deny) == 1 with input as with_input({"files": [{
		"path": "zones/example.com/services/search/records.yaml",
		"zone": "example.com",
		"records": [{"name": "a.b", "type": "CNAME", "values": ["x.pages.dev"]}],
	}]})
}

test_a_dotted_txt_name_is_allowed_inside_a_service if {
	count(layout.deny) == 0 with input as with_input({"files": [{
		"path": "zones/example.com/services/search/records.yaml",
		"zone": "example.com",
		"records": [{"name": "_acme-challenge.docs", "type": "TXT", "values": ["token"]}],
	}]})
}

test_delegated_service_must_not_have_records if {
	count(layout.deny) == 1 with input as with_input({"services": [service({
		"delegated": true,
		"delegation": {"type": "external", "nameservers": ["ns1.example.net"], "expires": "2027-03-01"},
		"has_records_file": true,
	})]})
}

test_delegation_must_expire if {
	count(layout.deny) == 1 with input as with_input({"services": [service({
		"delegated": true,
		"delegation": {"type": "external", "nameservers": ["ns1.example.net"]},
		"has_records_file": false,
	})]})
}

test_nothing_may_sit_below_a_delegation if {
	# The real case: a TXT record left in the parent zone after the namespace was
	# delegated away. It resolves from the child, so nobody notices the parent's
	# copy going stale.
	count(layout.deny) == 1 with input as with_input({
		"services": [service({
			"delegated": true,
			"delegation": {"type": "external", "nameservers": ["ns1.example.net"], "expires": "2027-03-01"},
			"has_records_file": false,
		})],
		"records": [record({
			"name": "search.example.com",
			"type": "TXT",
			"content": "ms-domain-verification=x",
			"source": "zones/example.com/validations/microsoft.yaml",
		})],
	})
}

test_the_delegation_ns_records_are_not_denied if {
	count(layout.deny) == 0 with input as with_input({
		"services": [service({
			"delegated": true,
			"delegation": {"type": "external", "nameservers": ["ns1.example.net"], "expires": "2027-03-01"},
			"has_records_file": false,
		})],
		"records": [record({
			"name": "search.example.com",
			"type": "NS",
			"content": "ns1.example.net",
			"source": "zones/example.com/services/search/service.yaml",
		})],
	})
}

# --- validations -----------------------------------------------------------

test_validation_cname_must_be_one_label if {
	count(layout.deny) == 1 with input as with_input({"validations": [validation({"cname": {"docs.search": "verify.hubspot.com"}})]})
}

test_validation_cname_must_not_be_at_the_apex if {
	count(layout.deny) == 1 with input as with_input({"validations": [validation({"cname": {"@": "verify.hubspot.com"}})]})
}

test_validation_requires_vendor_purpose_and_expires if {
	count(layout.deny) == 3 with input as with_input({"validations": [validation({
		"vendor": null,
		"purpose": null,
		"expires": null,
	})]})
}

test_validation_txt_must_not_enter_a_service_namespace if {
	count(layout.deny) == 1 with input as with_input({
		"services": [service({})],
		"validations": [validation({"txt": {"_token.search": ["x"]}})],
	})
}

test_validation_txt_may_be_dotted_outside_a_service if {
	count(layout.deny) == 0 with input as with_input({
		"services": [service({})],
		"validations": [validation({"txt": {"selector._domainkey": ["x"]}})],
	})
}

test_a_service_in_another_zone_does_not_constrain_this_one if {
	count(layout.deny) == 0 with input as with_input({
		"services": [service({"zone": "other.com", "path": "zones/other.com/services/search"})],
		"validations": [validation({"txt": {"_token.search": ["x"]}})],
	})
}

# --- the finished zone -----------------------------------------------------

test_a_cname_is_exclusive_at_its_name if {
	# The CNAME and the record it shadows are usually in different files owned by
	# different people, which is exactly why nobody spots this in review.
	count(layout.deny) == 1 with input as with_input({"records": [
		record({"name": "www.example.com", "type": "CNAME", "content": "example.pages.dev"}),
		record({"name": "www.example.com", "type": "TXT", "content": "hello"}),
	]})
}

test_records_of_one_type_at_one_name_are_fine if {
	count(layout.deny) == 0 with input as with_input({"records": [
		record({"name": "example.com", "type": "A", "content": "192.0.2.1"}),
		record({"name": "example.com", "type": "A", "content": "192.0.2.2"}),
	]})
}

# --- warnings --------------------------------------------------------------

test_an_expired_validation_warns if {
	count(layout.warn) == 1 with input as with_input({"validations": [validation({"expires": "2020-01-01"})]})
}

test_an_expired_delegation_warns if {
	count(layout.warn) == 1 with input as with_input({"services": [service({
		"expires": null,
		"delegated": true,
		"delegation": {"type": "external", "nameservers": ["ns1.example.net"], "expires": "2020-01-01"},
		"has_records_file": false,
	})]})
}

test_a_missing_date_is_not_an_expired_date if {
	count(layout.warn) == 0 with input as with_input({"services": [service({"expires": null})]})
}
