#!/bin/sh
set -eu
exec busted --loaders=lua,fennel --helper=tests/busted-helper.lua --pattern=_test packages tests
