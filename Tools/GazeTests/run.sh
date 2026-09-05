#!/bin/bash
set -u
cd "$(dirname "$0")"
P=../../WallpicsMac
SRC="main.swift Fixtures.swift $P/Pets/Render/GazeMap.swift $P/Pets/Core/PetModels.swift $P/Models/SubscriptionState.swift"
xcrun swiftc -O -DDEBUG -o gazetests-debug $SRC 2>&1 | grep -E "error" | head -5
[ -x ./gazetests-debug ] && ./gazetests-debug | grep -E "debug|FAIL"
xcrun swiftc -O -o gazetests $SRC 2>&1 | grep -E "error" | head -20
[ -x ./gazetests ] && ./gazetests
rm -f gazetests gazetests-debug
