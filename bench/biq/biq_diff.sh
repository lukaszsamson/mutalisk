#!/usr/bin/env bash
# usage: biq_diff.sh <target> <pre-label> <post-label>
S=${BIQ_DIR:-/tmp/biq_gate}/biq
for set in default env; do
  jq -r '(.schema+.fallback)[] | "\(.stable_id)\t\(.mutator)"' $S/$1.$2.$set.json | sort > $S/pre.txt
  jq -r '(.schema+.fallback)[] | "\(.stable_id)\t\(.mutator)"' $S/$1.$3.$set.json | sort > $S/post.txt
  echo "== $1 [$set] pre=$(wc -l <$S/pre.txt) post=$(wc -l <$S/post.txt) removed=$(comm -23 $S/pre.txt $S/post.txt | wc -l) added=$(comm -13 $S/pre.txt $S/post.txt | wc -l)"
  echo "-- removed by mutator:"; comm -23 $S/pre.txt $S/post.txt | cut -f2 | sort | uniq -c
  echo "-- added by mutator:";   comm -13 $S/pre.txt $S/post.txt | cut -f2 | sort | uniq -c
done
