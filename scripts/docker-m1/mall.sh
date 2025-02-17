#!/bin/sh
# (mall = manifest all)
# usage:
# ./mall.sh 2022-02-02 ABC1234

HERE=.
DATEVER="$1"
HASHVER="$2"

# shellcheck source=/dev/null
. ../../VERSION
if [ "$(printf '%s\n%s' "$DATEVER" "$HASHVER")" != "$(tail -n2 versions.txt)" ]; then
  echo 'Error: versions.txt is out of date'
  exit 1
fi

for VER in $(cat "$HERE/versions.txt") "$DATEVER" "$HASHVER" ; do
  ./manifest.sh "$VER" latest-amd64 latest-arm64
  ./mpush.sh "$VER"
done
