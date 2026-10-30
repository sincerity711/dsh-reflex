# Display Loom bridge

`VSCGVirtualDisplayBridge.m` and `include/VSCGVirtualDisplayBridge.h` are copied,
without implementation changes, from [Display Loom](https://github.com/narumiruna/display-loom)
commit `7d537c2` (2026-10-04), paths `DisplayLoom/Bridge/`.

Copyright (c) 2026 なるみ. MIT license; see `LICENSE.txt`. The helper bundle includes
that license under `Contents/Resources/ThirdParty/DisplayLoom-LICENSE.txt`.

Only the display creation/mode/lifetime bridge is used. Reflex supplies its own
corner placement and meeting window lifecycle; no preview, recording, streaming,
or login-item code is included. The bridge resolves private CoreGraphics classes
at runtime and reports unsupported systems. A future OS update can break it.
