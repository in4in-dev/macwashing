#!/bin/bash
# Once, on the maintainer's Mac: the two update signing keys. A fork that publishes its own builds runs it too.
#
#   Scripts/release/setup-keys.sh
#
# - Sparkle EdDSA (signs the DMGs in the appcast): Sparkle's own generate_keys (the key goes into the login keychain;
#   an existing one is reused).
# - Rules Ed25519 (signs the rules database manifests): Tools/SignRules, stored in the login keychain as a generic
#   password (service com.ovvi.MacWashing.rules-signing, account ed25519) through `security -i`, so it never shows in `ps`.
# Both private keys are also exported to MW_KEYS_BACKUP (default ~/MacWashing-update-keys, 700/600, never inside the
# repository): keep an encrypted copy off this Mac. Losing the Sparkle key means users can no longer update; losing
# the rules key means no new rules until an app release with a new MWRulesKeys.
# Then the public keys are written into App/Info.plist (SUPublicEDKey, MWRulesKeys): commit that.
# Needs the Sparkle package resolved once (any Xcode build of the app, e.g. a Debug build into build/).
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib-releases.sh
. "$(dirname "$0")/lib-releases.sh"

backup=${MW_KEYS_BACKUP:-$HOME/MacWashing-update-keys}
case $backup in "$repo"/*) die "MW_KEYS_BACKUP must be outside the repository" ;; esac
mkdir -p "$backup"
chmod 700 "$backup"

generate_keys=$(find "$repo/build" -path '*/artifacts/sparkle/Sparkle/bin/generate_keys' -type f 2>/dev/null | head -n 1)
[[ -n $generate_keys ]] || die "Sparkle's generate_keys not found under build/: build the app once (Debug is enough)"

step "Sparkle EdDSA key"
# `generate_keys -p` prints its error («No existing signing key found!») to stdout: judge by the exit status and the
# shape of a key (base64 of 32 bytes), never by "printed something".
is_key() { [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
if sparkle_public=$("$generate_keys" -p 2>/dev/null) && is_key "$sparkle_public"; then
    info "already in the login keychain (reused)"
else
    "$generate_keys" >/dev/null || die "generate_keys could not create the key (allow its keychain access when asked)"
    sparkle_public=$("$generate_keys" -p) && is_key "$sparkle_public" || die "generate_keys did not return a public key: $sparkle_public"
    info "created in the login keychain"
fi
if [[ ! -s $backup/sparkle-ed25519-private.txt ]]; then
    "$generate_keys" -x "$backup/sparkle-ed25519-private.txt" ||
        die "exporting the Sparkle key to $backup failed (allow keychain access when asked)"
    chmod 600 "$backup/sparkle-ed25519-private.txt"
fi
info "public: $sparkle_public"

step "Rules Ed25519 key"
signrules=(xcrun swift "$repo/Tools/SignRules/main.swift")
if private=$(security find-generic-password -s "$rules_service" -a "$rules_account" -w 2>/dev/null); then
    info "already in the login keychain (reused)"
else
    pair=$("${signrules[@]}" generate)
    private=$(sed -n 's/^private //p' <<<"$pair")
    printf 'add-generic-password -s %s -a %s -l "MacWashing rules signing key" -w %s\n' "$rules_service" "$rules_account" "$private" | security -i >/dev/null
    security find-generic-password -s "$rules_service" -a "$rules_account" >/dev/null || die "the rules key did not land in the keychain"
    info "created in the login keychain"
fi
rules_public=$(printf '%s' "$private" | "${signrules[@]}" public)
is_key "$rules_public" || die "the rules key in the keychain is not a valid Ed25519 key"
if [[ ! -s $backup/rules-ed25519-private.txt ]]; then
    (umask 077 && printf '%s\n' "$private" >"$backup/rules-ed25519-private.txt")
fi
unset private pair
info "public: $rules_public"

cat >"$backup/README.md" <<EOF
# Update signing keys of MacWashing (made by Scripts/release/setup-keys.sh)

- sparkle-ed25519-private.txt — Sparkle EdDSA private key. Restore: \`generate_keys -f sparkle-ed25519-private.txt\`.
  Public (Info.plist SUPublicEDKey): $sparkle_public
- rules-ed25519-private.txt — rules manifest key (base64 of the raw 32 bytes). Restore:
  \`security -i\`, then type \`add-generic-password -s $rules_service -a $rules_account -w <the key>\` (so it never shows
  in \`ps\`).
  Public (Info.plist MWRulesKeys): $rules_public

Keep an encrypted copy off this Mac.
EOF

step "App/Info.plist"
python3 - "$repo/App/Info.plist" "$sparkle_public" "$rules_public" <<'EOF'
import re, sys
path, sparkle, rules = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
for key, value in (("SUPublicEDKey", sparkle), ("MWRulesKeys", rules)):
    pattern = re.compile(r"(<key>%s</key>\s*<string>)([^<]*)(</string>)" % key)
    current = pattern.search(text)
    if not current:
        sys.exit(f"{key} is missing in {path}")
    if current.group(2) and current.group(2) != value and value not in current.group(2).split(","):
        sys.exit(f"{key} already holds another key ({current.group(2)}); replace it by hand if that is intended")
    text = pattern.sub(lambda m: m.group(1) + value + m.group(3), text, count=1)
open(path, "w", encoding="utf-8").write(text)
EOF
plutil -lint "$repo/App/Info.plist" >/dev/null
info "SUPublicEDKey and MWRulesKeys written; commit App/Info.plist"
info "backups: $backup (copy them off this Mac, encrypted)"
