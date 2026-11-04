#!/bin/sh
# =============================================================================
# list.sh — GET installed packs + remote manifest view
# =============================================================================
# Query params:
#   manifest_url (optional) — override the remote manifest URL. If absent, the
#     caller's view degrades to installed-only (client handles manifest URL).
# Response:
#   { installed: [{ code, version }...], manifest: {...}|null,
#     manifest_error: string|null }
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/language_packs.sh

qlog_init "lp_list"

INSTALLED=$(lp_list_installed)

# Parse manifest_url from QUERY_STRING. Keep naive — only one param expected.
_manifest_url=""
if [ -n "$QUERY_STRING" ]; then
    _manifest_url=$(printf '%s' "$QUERY_STRING" | awk 'BEGIN{RS="&"; FS="="} $1=="manifest_url"{print $2}' | head -1)
    # URL-decode: only handle %XX sequences. Use printf %b after awk gsub.
    _manifest_url=$(printf '%s' "$_manifest_url" | awk '
        BEGIN { o = "" }
        {
            s = $0
            while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
                o = o substr(s, 1, RSTART-1)
                hex = substr(s, RSTART+1, 2)
                cmd = "printf \"\\x" hex "\""
                cmd | getline ch
                close(cmd)
                o = o ch
                s = substr(s, RSTART + 3)
            }
            o = o s
        }
        END { print o }
    ')
fi

MANIFEST_JSON="null"
MANIFEST_ERR="null"
if [ -n "$_manifest_url" ]; then
    _body=$(lp_fetch_manifest "$_manifest_url" 2>/dev/null)
    if [ -n "$_body" ]; then
        MANIFEST_JSON="$_body"
    else
        MANIFEST_ERR='"unreachable"'
    fi
fi

cgi_headers
jq -n --argjson installed "$INSTALLED" \
      --argjson manifest "$MANIFEST_JSON" \
      --argjson manifest_error "$MANIFEST_ERR" \
      '{installed:$installed, manifest:$manifest, manifest_error:$manifest_error}'
