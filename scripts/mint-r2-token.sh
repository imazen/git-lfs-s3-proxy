#!/usr/bin/env bash
# mint-r2-token.sh — create a NON-EXPIRING R2 API token scoped to ONE bucket and
# print the S3 credential pair Git LFS will carry in its server URL.
#
#   CLOUDFLARE_ACCOUNT_ID=…  CLOUDFLARE_MINT_TOKEN=…  \
#     scripts/mint-r2-token.sh <bucket> <read|write> <token-name>
#
# CLOUDFLARE_MINT_TOKEN must be an API token that carries "Account API Tokens
# Write" (it is NOT the token you deploy with, and NOT an R2 S3 key). Output is
# three shell-sourceable lines: TOKEN_ID, ACCESS_KEY_ID, SECRET_ACCESS_KEY.
# Redirect it straight into a mode-600 file; do not paste it around.
#
# Facts this script depends on (verified against the live API):
#   - the S3 Access Key ID is the token's id; the Secret Access Key is the
#     SHA-256 hex digest of the token's value
#   - bucket scoping is the permission group "Workers R2 Storage Bucket Item
#     Read" / "… Write", resolved BY NAME (ids differ between accounts/docs),
#     on the resource com.cloudflare.edge.r2.bucket.<account>_default_<bucket>
#   - omitting expires_on makes the token permanent
#   - a fresh token can take a minute or two to become active
set -euo pipefail
bucket=${1:?bucket}; perm=${2:?read|write}; name=${3:?token-name}
: "${CLOUDFLARE_ACCOUNT_ID:?}" "${CLOUDFLARE_MINT_TOKEN:?}"
API=https://api.cloudflare.com/client/v4
case "$perm" in
  read)  pgname="Workers R2 Storage Bucket Item Read" ;;
  write) pgname="Workers R2 Storage Bucket Item Write" ;;
  *) echo "permission must be read or write" >&2; exit 2 ;;
esac
pgid=$(curl -sS -H "Authorization: Bearer $CLOUDFLARE_MINT_TOKEN" \
        "$API/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/permission_groups" \
      | python3 -c '
import json,sys
want=sys.argv[1]; d=json.load(sys.stdin)
if not d.get("success"): print(d.get("errors"), file=sys.stderr); sys.exit(1)
ids=[g["id"] for g in d["result"] if g["name"]==want]
if not ids:
    near=[g["name"] for g in d["result"] if "R2" in g["name"]]
    print(f"no permission group named {want!r}; R2 groups: {near}", file=sys.stderr); sys.exit(1)
print(ids[0])' "$pgname")
res="com.cloudflare.edge.r2.bucket.${CLOUDFLARE_ACCOUNT_ID}_default_${bucket}"
body=$(python3 -c '
import json,sys
print(json.dumps({"name": sys.argv[1], "policies": [{"effect": "allow",
  "permission_groups": [{"id": sys.argv[2]}], "resources": {sys.argv[3]: "*"}}]}))' \
  "$name" "$pgid" "$res")
curl -sS -X POST -H "Authorization: Bearer $CLOUDFLARE_MINT_TOKEN" \
  -H 'Content-Type: application/json' -d "$body" \
  "$API/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens" \
| python3 -c '
import json,sys,hashlib
r=json.load(sys.stdin)
if not r.get("success"): print(r.get("errors"), file=sys.stderr); sys.exit(1)
t=r["result"]
print("TOKEN_ID=%s" % t["id"])
print("ACCESS_KEY_ID=%s" % t["id"])
print("SECRET_ACCESS_KEY=%s" % hashlib.sha256(t["value"].encode()).hexdigest())'
