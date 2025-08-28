#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# fix-password-validation.sh - Targeted fix for password validation regex issue


echo "🔧 Fixing password validation regex in generate-credentials.sh..."

# Backup the current file
cp generate-credentials.sh generate-credentials.sh.fix-backup-$(date +%s)

# Find and fix the problematic regex pattern
if grep -q "\\\\!\\\\@" generate-credentials.sh; then
    echo "  📝 Found problematic escaped regex pattern"
    # Replace the over-escaped pattern with the correct one
    sed -i 's/\[\\\!\\\@\\\#\\\$\\\%\\\^\\\&\\\*\\\(\\\)\_\\\+\\\-\\\=\\\[\\\]\\\{\\\}\\\|\\\;\\\:\\\,\\\.\\\<\\\>\\\?\]/[^a-zA-Z0-9]/g' generate-credentials.sh
    echo "  ✅ Fixed regex pattern"
elif grep -q "\[\^a-zA-Z0-9\]" generate-credentials.sh; then
    echo "  ✅ Regex pattern is already correct"
else
    echo "  ❓ No recognizable special character pattern found"
    echo "  📝 Searching for any special character validation..."
    grep -n "special.*character\|SPECIAL" generate-credentials.sh || echo "  ❌ No special character validation found"
fi

echo "✅ Password validation fix completed!"
