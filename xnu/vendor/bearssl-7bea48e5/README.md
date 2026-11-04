# BearSSL 7bea48e5 (saved copy)

The files `xnu/patches/0020-stage-bearssl.sh` takes from BearSSL commit
`7bea48e5e850ab4cafbe68d3765cdaba13a86d6f` (https://www.bearssl.org/git/BearSSL),
unchanged. BearSSL is MIT licensed; see `LICENSE.txt`.

The script still fetches that commit from bearssl.org first. It uses this copy
only after 4 failed fetches (bearssl.org answered 502 on every try in run
41835586448), and only when every file here matches `SHA256SUMS` and no
unlisted file is present.

Source: the staged `libkern/crypto/sweet_bearssl` folder in the
`xnu-buildtree-macos-15-intel` artifact of run 41828220161, whose fetch of the
pinned commit succeeded. The script's one edit there (`inner.h` includes
`machine/limits.h` in the kernel) was undone, so these are the upstream files.
