#!/bin/sh
# usage:
# ./m1-stuff.sh 2022-02-02 abc1234

DATEVER="$1"
HASHVER="$2"

if [ "x$DATEVER" = "x" ] ; then echo DATEVER required; exit 1; fi;
if [ "x$HASHVER" = "x" ] ; then echo HASHVER required; exit 1; fi;

# run this after building all images so that 'latest' is the m1 stuff
./retag.sh latest latest-arm64
./push.sh latest-arm64
./pull.sh latest
./retag.sh latest latest-amd64
# ./info.sh latest-amd64 # visually inspect that all issue platform warning 
./push.sh latest-amd64
# ./inspect.sh latest-amd64 # visually inspect that all are amd64
# ./inspect.sh latest-arm64 # visually inspect that all are arm64
./mall.sh "$DATEVER" "$HASHVER"
# check  that it worked
# ./inspect.sh latest # visuall inspect that they are all both amd64 and arm64
# ./pull.sh latest   # (only reach-cli:latest is needed)
# ../../reach update
# ../../reach hashes
