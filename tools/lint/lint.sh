#!/bin/sh
# Syntax, unknown-global and `_`-shadowing checks for every KO-Plus Lua file.
set -e
cd "$(dirname "$0")"
[ -d node_modules/luaparse ] || npm install --silent >/dev/null
FILES=$(find ../../src -name '*.lua')
node check.js $FILES
node globals.js $FILES
node shadow.js $FILES
