#!/bin/bash
cd "$(dirname "$0")"
xattr -cr Mochi.app 2>/dev/null
echo "Fixed. Open Mochi.app now."
open Mochi.app
