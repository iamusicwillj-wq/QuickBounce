# LAME integration

QuickBounce uses [LAME 3.100](https://lame.sourceforge.io/) for WAV-to-MP3 conversion. The upstream header in `Sources/QuickBounceLAMEShim/include/lame.h` retains its copyright and LGPL notice. The original [COPYING](COPYING), [LICENSE](LICENSE) and [README](README.upstream) files are preserved here.

Run `./Tools/build_lame.sh` from the repository root to download the upstream source archive, verify its SHA-256 and build `Sources/QuickBounceLAMEShim/lib/libmp3lame.a` locally for arm64 and x86_64. QuickBounce statically links the resulting library.

The app bundle includes copies of the upstream license and notices under `Contents/Resources/Licenses/LAME`. Distribution of the linked app is subject to the applicable LGPL terms.
