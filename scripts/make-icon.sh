#!/bin/zsh
# Regenerates Resources/AppIcon.icns from the drawing in PulseLogo.swift.
set -euo pipefail
cd "${0:A:h:h}"
swift build
.build/debug/Pulse --make-icon Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
