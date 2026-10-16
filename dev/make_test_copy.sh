#!/bin/sh
# usage: ./make_test_copy.sh https://YOURREF.supabase.co YOUR_ANON_KEY [login_domain]
# writes index.html / report.html into ./test_copy pointing at YOUR Supabase
[ -z "$2" ] && { echo "usage: $0 <url> <anon_key> [login_domain]"; exit 1; }
SRC=$(dirname "$0")/..
OUT=$(dirname "$0")/test_copy
DOM=${3:-test-shop.com}
mkdir -p "$OUT"
for f in index.html report.html; do
  sed -E "s|^const supabaseUrl = .*|const supabaseUrl = '$1'|; s|^const supabaseKey = .*|const supabaseKey = '$2'|; s|^const LOGIN_DOMAIN = '[^']*'|const LOGIN_DOMAIN = '$DOM'|" "$SRC/$f" > "$OUT/$f"
done
echo "done -> $OUT   (login as  name@$DOM)"
