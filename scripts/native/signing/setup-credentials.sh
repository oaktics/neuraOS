#!/bin/bash
# Run interactively on the developer's Mac. Never enable shell tracing here.
set -euo pipefail
set +x
repo=oaktics/neuraOS
identity='Developer ID Application: Kiichi Sato (3BNMLRRV2K)'
team=3BNMLRRV2K
if [ ! -t 0 ]; then
  printf 'Run this script in an interactive terminal.\n' >&2
  exit 1
fi
gh auth status >/dev/null
printf 'Configure notarization in your login Keychain and Actions secrets in %s.\n' "$repo"
printf 'Export ONLY "%s" with its private key as a password-protected .p12 first.\n' "$identity"
read -r -p 'Path to the .p12 file: ' certificate
test -f "$certificate"
read -r -s -p 'Password used when exporting the .p12: ' certificate_password
printf '\n'
test -n "$certificate_password"
read -r -p 'Apple Account email: ' apple_id
test -n "$apple_id"
read -r -s -p 'App-specific password (not your Apple Account login password): ' notary_password
printf '\n'
test -n "$notary_password"
trap 'unset certificate_password notary_password' EXIT
# Apple's Keychain export may use RC2, which Homebrew OpenSSL 3 disables by
# default. macOS's bundled LibreSSL can validate these exports without loading
# a legacy provider or changing the user's global crypto configuration.
printf '%s\n' "$certificate_password" | /usr/bin/openssl pkcs12 -in "$certificate" -noout -passin stdin
# Validate with Apple before changing repository secrets. The passwords are not
# command history, source files or printed output. notarytool stores in Keychain.
xcrun notarytool store-credentials neura-local --apple-id "$apple_id" --team-id "$team" --password "$notary_password"
base64 < "$certificate" | gh secret set APPLE_CERTIFICATE_P12_BASE64 --repo "$repo"
printf '%s' "$certificate_password" | gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$repo"
printf '%s' "$apple_id" | gh secret set APPLE_ID --repo "$repo"
printf '%s' "$team" | gh secret set APPLE_TEAM_ID --repo "$repo"
printf '%s' "$notary_password" | gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo "$repo"
gh variable set APPLE_SIGN_IDENTITY --repo "$repo" --body "$identity"
printf 'Configured. Secret values were not printed. Keep the .p12 backup in secure storage.\n'
