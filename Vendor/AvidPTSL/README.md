# Avid PTSL build input

QuickBounce links against `PTSLC_CPP.framework`. Obtain the [C++ Pro Tools Scripting SDK from Avid](https://developer.avid.com/scripting/) and follow the applicable SDK terms. The SDK and compiled framework are local build inputs.

QuickBounce was developed with SDK `2026.04.0.1301892`. Unpack it in the repository root using that versioned folder name, then run

```sh
./Tools/build_ptsl.sh
```

The script defaults to `python3.12` on your PATH and asks Avid's build script to compile a Universal 2 framework targeting macOS 14. Avid's build may download dependencies. Set `QUICKBOUNCE_PTSL_SDK_ROOT` if the SDK is stored elsewhere and `QUICKBOUNCE_PTSL_PYTHON` if you use a different compatible Python executable.

If you already have a compatible Universal 2 framework, copy it to `Vendor/AvidPTSL/PTSLC_CPP.framework`, keeping its symlinks intact. SwiftPM uses the headers and library at that path.
