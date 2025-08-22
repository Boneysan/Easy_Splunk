#!/bin/bash
# Quick if/fi matcher for runtime-detection.sh

file="lib/runtime-detection.sh"
if_count=0
fi_count=0
line_num=0

while IFS= read -r line; do
  ((line_num++))
  
  # Count if statements (including elif)
  if [[ $line =~ ^[[:space:]]*if[[:space:]] || $line =~ [[:space:]]+if[[:space:]] ]]; then
    ((if_count++))
    echo "Line $line_num: IF ($if_count) - $line"
  fi
  
  # Count fi statements
  if [[ $line =~ ^[[:space:]]*fi[[:space:]]*$ ]]; then
    ((fi_count++))
    echo "Line $line_num: FI ($fi_count) - $line"
  fi
  
done < "$file"

echo ""
echo "Summary: $if_count if statements, $fi_count fi statements"
echo "Missing fi statements: $((if_count - fi_count))"
