#!/usr/bin/env bash
# mint-deploy-token.sh — create the API token wrangler uses to deploy this proxy
# onto a custom domain: Workers Scripts on the account, plus Workers Routes / DNS
# / SSL / Zone Read on the one zone that hosts the domain.
#
#   CLOUDFLARE_ACCOUNT_ID=…  CLOUDFLARE_MINT_TOKEN=…  \
#     scripts/mint-deploy-token.sh <token-name> <zone-id>
#
# Prints one line, CLOUDFLARE_API_TOKEN=<value>; redirect it into a mode-600
# file and `source` that before `npx wrangler deploy`.
set -euo pipefail
name=${1:?token-name}; zone=${2:?zone-id}
: "${CLOUDFLARE_ACCOUNT_ID:?}" "${CLOUDFLARE_MINT_TOKEN:?}"
API=https://api.cloudflare.com/client/v4
curl -sS -H "Authorization: Bearer $CLOUDFLARE_MINT_TOKEN" \
  "$API/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/permission_groups" > "${TMPDIR:-$HOME/tmp}/cf-pg.json"
body=$(python3 - "$name" "$zone" "$CLOUDFLARE_ACCOUNT_ID" "${TMPDIR:-$HOME/tmp}/cf-pg.json" <<'PY'
import json,sys
name, zone, acct, pgfile = sys.argv[1:5]
d = json.load(open(pgfile))
if not d.get("success"): print(d.get("errors"), file=sys.stderr); sys.exit(1)
byname = {}
for g in d["result"]:
    byname.setdefault(g["name"], g["id"])
def ids(names):
    out = []
    for n in names:
        if n not in byname:
            near = sorted(k for k in byname if n.split()[0] in k)
            print(f"no permission group named {n!r}; similar: {near}", file=sys.stderr); sys.exit(1)
        out.append({"id": byname[n]})
    return out
account_pg = ids(["Workers Scripts Write", "Account Settings Read", "Workers Tail Read"])
zone_pg = ids(["Workers Routes Write", "Zone Read", "DNS Write", "SSL and Certificates Write"])
print(json.dumps({"name": name, "policies": [
  {"effect": "allow", "permission_groups": account_pg,
   "resources": {f"com.cloudflare.api.account.{acct}": "*"}},
  {"effect": "allow", "permission_groups": zone_pg,
   "resources": {f"com.cloudflare.api.account.zone.{zone}": "*"}},
]}))
PY
)
curl -sS -X POST -H "Authorization: Bearer $CLOUDFLARE_MINT_TOKEN" \
  -H 'Content-Type: application/json' -d "$body" \
  "$API/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens" \
| python3 -c '
import json,sys
r=json.load(sys.stdin)
if not r.get("success"): print(r.get("errors"), file=sys.stderr); sys.exit(1)
print("CLOUDFLARE_API_TOKEN=%s" % r["result"]["value"])
print("# token id %s" % r["result"]["id"])'
