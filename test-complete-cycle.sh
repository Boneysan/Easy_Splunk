#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt



echo "=== Complete Encrypt/Decrypt Cycle Test ==="

# Extract the functions exactly as they are in deploy.sh
source <(sed -n '/^simple_encrypt()/,/^}/p; /^simple_decrypt()/,/^}/p' /mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk/deploy.sh)

TEST_DATA="admin"
TEST_KEY="test_key_12345678901234567890123456789012"

echo "Step 1: Encrypt with our function"
if ENCRYPTED=$(simple_encrypt "$TEST_DATA" "$TEST_KEY"); then
    echo "✓ Encryption successful: '$ENCRYPTED'"
    echo "Encrypted length: ${#ENCRYPTED}"
    
    echo "Step 2: Decrypt with our function"
    if DECRYPTED=$(simple_decrypt "$ENCRYPTED" "$TEST_KEY"); then
        echo "✓ Decryption successful: '$DECRYPTED'"
        
        if [[ "$DECRYPTED" == "$TEST_DATA" ]]; then
            echo "✓ Complete cycle: PASS"
        else
            echo "✗ Complete cycle: FAIL ('$DECRYPTED' != '$TEST_DATA')"
            exit 1
        fi
    else
        echo "✗ Decryption failed"
        
        # Try manual decryption of the same data
        echo "Manual decryption test..."
        export MANUAL_KEY="$TEST_KEY"
        echo "$ENCRYPTED" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass env:MANUAL_KEY || echo "Manual also failed"
        unset MANUAL_KEY
        exit 1
    fi
else
    echo "✗ Encryption failed"
    exit 1
fi

echo -e "\n🎉 COMPLETE ENCRYPTION CYCLE WORKS!"
