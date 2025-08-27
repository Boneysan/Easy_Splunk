#!/usr/bin/env bash
set -euo pipefail

KEY=$(cat credentials/.session_key)
USER_ENC=$(cat credentials/splunk_admin_user.enc)
PASS_ENC=$(cat credentials/splunk_admin_password.enc)

printf "User (enc): %s\n" "$USER_ENC"
printf "User (dec): %s\n" "$(printf '%s' "$USER_ENC" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$KEY")"
printf "Pass (enc): %s\n" "$PASS_ENC"
printf "Pass (dec): %s\n" "$(printf '%s' "$PASS_ENC" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$KEY")"
