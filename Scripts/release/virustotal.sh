#!/bin/bash
# Uploads a release DMG to VirusTotal and waits for its report: an optional check before publish-release.sh.
#
#   Scripts/release/virustotal.sh <file.dmg>
#
# The API key (virustotal.com → profile → API key; the free public key is enough: 4 requests a minute), first found of:
# MW_VIRUSTOTAL_KEY; the login keychain (`security add-generic-password -s "MacWashing VirusTotal" -a api-key -w` asks
# for it, nothing in history). A file VirusTotal already knows is not uploaded again: its last report is used.
#
# Exit: 0 — no engine flags the file; 2 — some engines flag it (malicious or suspicious; the report link is printed:
# usually a false positive, each vendor has a form to clear it); 3 — VirusTotal does not have the file (no key, the key
# refused, no network, the upload failed); 1 — uploaded, but no report within 10 minutes (it comes later).
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib-releases.sh
. "$(dirname "$0")/lib-releases.sh"

file=${1:?usage: virustotal.sh <file.dmg>}
[[ -f $file ]] || { warn "VirusTotal: no file $file"; exit 3; }
api=https://www.virustotal.com/api/v3
service="MacWashing VirusTotal"

key=${MW_VIRUSTOTAL_KEY:-}
[[ -n $key ]] || key=$(security find-generic-password -s "$service" -a api-key -w 2>/dev/null || true)
if [[ -z $key ]]; then
    warn "VirusTotal: no API key (MW_VIRUSTOTAL_KEY or keychain «$service»; see the head of $0)"
    exit 3
fi

sha=$(shasum -a 256 "$file" | cut -d' ' -f1)
gui=https://www.virustotal.com/gui/file/$sha
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mw-virustotal.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# get <path> → the body in $tmp/body, the HTTP status on stdout. The key goes in a header from a file, never in argv.
printf 'x-apikey: %s\n' "$key" >"$tmp/header"
chmod 600 "$tmp/header"
get() { curl -sS -o "$tmp/body" -w '%{http_code}' -H @"$tmp/header" "$api$1" || echo 000; }
stats() { # malicious suspicious undetected of the file's last analysis
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["data"]["attributes"]["last_analysis_stats"]; print(s.get("malicious",0), s.get("suspicious",0), s.get("undetected",0)+s.get("harmless",0))' "$tmp/body"
}
analysed() { # the file has a finished analysis (an uploaded file shows up before its engines are done)
    python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["data"]["attributes"]; s=a.get("last_analysis_stats",{}); sys.exit(0 if a.get("last_analysis_date") and sum(s.values()) else 1)' "$tmp/body"
}

step "VirusTotal: $(basename "$file") ($sha)"
status=$(get "/files/$sha")
case $status in
    200) analysed || status=pending ;;
    404) ;;
    401 | 403) warn "VirusTotal: the API key was refused ($status)"; exit 3 ;;
    *) warn "VirusTotal: no answer ($status)"; exit 3 ;;
esac

if [[ $status == 404 ]]; then
    info "uploading…"
    code=$(curl -sS -o "$tmp/body" -w '%{http_code}' -H @"$tmp/header" -F "file=@$file" "$api/files" || echo 000)
    [[ $code == 200 ]] || { warn "VirusTotal: upload failed ($code): $(head -c 300 "$tmp/body")"; exit 3; }
fi
if [[ $status != 200 ]]; then
    # The public API allows 4 requests a minute: look every 30 s, give up after 10 min (the report still comes later).
    for _ in $(seq 1 20); do
        sleep 30
        status=$(get "/files/$sha")
        [[ $status == 200 ]] && analysed && break
        status=pending
    done
    [[ $status == 200 ]] || { warn "VirusTotal: no report after 10 minutes — check later: $gui"; exit 1; }
fi

read -r malicious suspicious clean < <(stats)
if [[ $((malicious + suspicious)) -gt 0 ]]; then
    warn "VirusTotal: $malicious engine(s) say malicious, $suspicious suspicious — $gui"
    exit 2
fi
info "VirusTotal: no engine flags it ($clean checked) — $gui"
