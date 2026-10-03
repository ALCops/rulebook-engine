#!/usr/bin/env bash
# Method 3: regex scan of DLL bytes with strings (UTF-16LE user strings and 8-bit strings).
# Usage: m3-scan.sh <out-prefix> <dll>...   writes <out-prefix>.exact.txt (whole string = id) and <out-prefix>.embedded.txt (id anywhere in a string)
set -euo pipefail
out=$1; shift
RX='(AA|AW|AS|PTE|AL|LC|AC|DC|FC|PC|TA|TAC|CM)[0-9]{4}'
start=$(date +%s%N)
: > "$out.all"
for f in "$@"; do { strings -e l "$f"; strings "$f"; } >> "$out.all"; done
grep -E "^${RX}\$" "$out.all" | sort -u > "$out.exact.txt" || true
grep -oE "\b${RX}i?\b" "$out.all" | sort -u > "$out.embedded.txt" || true
end=$(date +%s%N)
echo "m3 $out: exact $(wc -l < "$out.exact.txt") ids, embedded $(wc -l < "$out.embedded.txt") ids, $(awk -v a=$start -v b=$end "BEGIN{printf \"%.2f\", (b-a)/1e9}") s"
for p in AA AW AS PTE AL LC AC DC FC PC TA CM; do printf '%s exact=%s embedded=%s; ' $p "$(grep -c "^$p[0-9]" "$out.exact.txt" || true)" "$(grep -c "^$p[0-9]" "$out.embedded.txt" || true)"; done; echo
rm -f "$out.all"
