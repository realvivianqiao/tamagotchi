#!/bin/bash
cd "$(dirname "$0")"
xattr -cr CoPet.app 2>/dev/null
echo "Fixed. Open CoPet.app now."
open CoPet.app
