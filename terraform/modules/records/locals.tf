# ---------------------------------------------------------------------------
# YAML -> DNS records
#
# This file and tools/dnsctl.py implement the same mapping from the repository
# layout to a flat set of records. Terraform is what applies; dnsctl is what
# validates and what compares against the live zone. If you change the mapping
# here, change it there.
#
# Three things are computed from the path and never read from a file, because a
# value that is never written cannot be written wrongly:
#
#   apex/*.yaml                  names are relative to the zone apex
#   validations/*.yaml           names are relative to the zone apex
#   services/<dir>/records.yaml  names are relative to <dir>.<zone>
#
# ---------------------------------------------------------------------------

locals {
  zone_cfg = yamldecode(file("${var.zone_dir}/zone.yaml"))

  ttl_default    = try(local.zone_cfg.ttl.default, 1)
  ttl_validation = try(local.zone_cfg.ttl.validation, local.ttl_default)

  # Record types whose content is a host name. Cloudflare stores these without
  # a trailing dot, so trim one if the YAML supplied it. Trimming is confined
  # to these types: a TXT value that ends in a dot ends in a dot on purpose.
  hostname_types = ["CNAME", "MX", "NS", "PTR", "SRV"]

  # --- apex ---------------------------------------------------------------
  # Answers at the apex or directly below it. Critical approvers own these.

  apex_files = fileset(var.zone_dir, "apex/*.yaml")

  apex_records = flatten([
    for f in local.apex_files : [
      for r in try(yamldecode(file("${var.zone_dir}/${f}")).records, []) : [
        for v in r.values : {
          source   = f
          name     = r.name == "@" ? var.zone_name : "${r.name}.${var.zone_name}"
          type     = r.type
          content  = v
          proxied  = try(r.proxied, false)
          priority = try(r.priority, null)
          # A proxied record is served by Cloudflare, which controls its TTL.
          # The provider rejects any other value, so do not let a file supply
          # one: the file cannot be wrong about something it does not decide.
          ttl = try(r.proxied, false) ? 1 : try(r.ttl, local.ttl_default)
        }
      ]
    ]
  ])

  # --- validations --------------------------------------------------------
  # Proof of ownership for a vendor. A map of names, not a list of records:
  # there is no `type` field, so an MX or NS record has nowhere to be written.

  validation_files = fileset(var.zone_dir, "validations/*.yaml")

  validation_txt = flatten([
    for f in local.validation_files : [
      for name, values in try(yamldecode(file("${var.zone_dir}/${f}")).txt, {}) : [
        for v in values : {
          source   = f
          name     = name == "@" ? var.zone_name : "${name}.${var.zone_name}"
          type     = "TXT"
          content  = v
          proxied  = false
          priority = null
          ttl      = local.ttl_validation
        }
      ]
    ]
  ])

  # One name, one target: a CNAME is exclusive at its name, and the schema says
  # so by mapping to a string rather than to a list.
  validation_cname = flatten([
    for f in local.validation_files : [
      for name, target in try(yamldecode(file("${var.zone_dir}/${f}")).cname, {}) : {
        source   = f
        name     = "${name}.${var.zone_name}"
        type     = "CNAME"
        content  = target
        proxied  = false
        priority = null
        ttl      = local.ttl_validation
      }
    ]
  ])

  # --- services -----------------------------------------------------------
  # One directory for each team subdomain. The namespace is the directory name.

  service_files = fileset(var.zone_dir, "services/*/service.yaml")

  services = {
    for f in local.service_files :
    split("/", f)[1] => yamldecode(file("${var.zone_dir}/${f}"))
  }

  service_record_files = fileset(var.zone_dir, "services/*/records.yaml")

  service_records = flatten([
    for f in local.service_record_files : [
      for r in try(yamldecode(file("${var.zone_dir}/${f}")).records, []) : [
        for v in r.values : {
          source = f
          name = r.name == "@" ? (
            "${split("/", f)[1]}.${var.zone_name}"
            ) : (
            "${r.name}.${split("/", f)[1]}.${var.zone_name}"
          )
          type     = r.type
          content  = v
          proxied  = try(r.proxied, false)
          priority = try(r.priority, null)
          ttl      = try(r.proxied, false) ? 1 : try(r.ttl, local.ttl_default)
        }
      ]
    ]
  ])

  # Delegation is a property of the service, not a record the team writes. The
  # NS records come from service.yaml, which service approvers own, so a team
  # cannot delegate its own namespace away.
  delegation_records = flatten([
    for dir, svc in local.services : [
      for ns in try(svc.delegation.nameservers, []) : {
        source   = "services/${dir}/service.yaml"
        name     = "${dir}.${var.zone_name}"
        type     = "NS"
        content  = ns
        proxied  = false
        priority = null
        ttl      = local.ttl_default
      }
    ] if try(svc.delegation.type, null) == "external"
  ])

  # --- the flat set -------------------------------------------------------

  all_records = concat(
    local.apex_records,
    local.validation_txt,
    local.validation_cname,
    local.service_records,
    local.delegation_records,
  )

  normalised = [
    for r in local.all_records : merge(r, {
      name    = lower(r.name)
      type    = upper(r.type)
      content = contains(local.hostname_types, upper(r.type)) ? trimsuffix(r.content, ".") : r.content

      # What the provider is actually given. For every type but TXT this is the
      # value itself; see the comment on txt_wire below for why TXT is not.
      provider_content = upper(r.type) != "TXT" ? (
        contains(local.hostname_types, upper(r.type)) ? trimsuffix(r.content, ".") : r.content
      ) : local.txt_wire[r.content]
    })
  ]

  # Cloudflare requires TXT content in its zone-file form: each string wrapped
  # in double quotes, and split into 255-character strings once it is longer
  # than one, because that is the largest a single character-string may be.
  #
  # The provider does not do this. It sends what the configuration says and
  # stores what the API returns, and the API returns the quoted form. So an
  # unquoted `content` produces a record the Cloudflare dashboard marks as
  # invalid (cloudflare/terraform-provider-cloudflare#6354) and a plan that
  # shows the same change every time it runs, for ever.
  #
  # The YAML stays unquoted, because a file that says
  # `["v=spf1 include:icloud.com ~all"]` is a file that says what it means. The
  # quoting is a property of the wire format, so it belongs here.
  #
  # Chunking counts characters, not bytes. DNS counts bytes. Every value this
  # has to carry -- SPF, DKIM, DMARC, vendor verification tokens -- is ASCII,
  # where the two are the same.
  txt_values = toset([for r in local.all_records : r.content if upper(r.type) == "TXT"])

  txt_wire = {
    for value in local.txt_values : value => length(value) == 0 ? "\"\"" : join(" ", [
      for chunk in regexall("(?s).{1,255}", value) :
      "\"${replace(replace(chunk, "\\", "\\\\"), "\"", "\\\"")}\""
    ])
  }

  # The key is the record itself: name, type, value. Two consequences worth
  # knowing. Moving a record between files does not touch DNS, because the file
  # is not part of the key. Changing a value is a delete and a create rather
  # than an edit, because it is a different key.
  #
  # Terraform refuses to build this map if two entries produce the same key, so
  # the same record written twice in two files is a hard error and not a silent
  # last-one-wins.
  records = {
    for r in local.normalised : "${r.name}|${r.type}|${r.content}" => r
  }
}
