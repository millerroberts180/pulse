#!/bin/zsh
# Runs the unit tests. The Command Line Tools ship Swift Testing, but SwiftPM
# doesn't add its framework path by itself; Xcode does. They also ship its
# Foundation overlay without the module, so a test that imports Foundation
# would fail to build; the overlay only adds conveniences, so it's turned off.
set -euo pipefail
cd "${0:A:h:h}"

frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d $frameworks ]]; then
  swift test -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xswiftc -F -Xswiftc $frameworks -Xlinker -F -Xlinker $frameworks -Xlinker -rpath -Xlinker $frameworks "$@"
else
  swift test "$@"
fi
