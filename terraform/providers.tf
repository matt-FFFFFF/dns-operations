# Authentication comes from the environment, never from a file in this
# repository:
#
#   export CLOUDFLARE_API_TOKEN=...
#
# The token needs Zone:DNS:Edit on every zone under zones/. If any zone.yaml
# leaves zone_id null, it also needs Zone:Zone:Read so the zone can be found by
# name.
provider "cloudflare" {}
