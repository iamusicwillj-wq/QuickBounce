# Build QuickBounce from source

Use macOS and Xcode with Swift 6 or later. The app supports macOS 14 and later and the packaging script builds for both Apple silicon and Intel. Run the commands from the repository root.

## Install the build inputs

1. Obtain the C++ Pro Tools Scripting SDK version `2026.04.0.1301892` from [Avid](https://developer.avid.com/scripting/) under the applicable terms. Follow the [PTSL setup instructions](../Vendor/AvidPTSL/README.md) to build or install the local framework.
2. Build LAME 3.100. The script downloads the upstream archive, checks its SHA-256 and builds a Universal 2 static library.

   ```sh
   ./Tools/build_lame.sh
   ```

## Test and build

```sh
swift test -Xlinker -rpath -Xlinker "$PWD/Vendor/AvidPTSL"
./Tools/build_app.sh
```

The automated tests link against the PTSL framework and exercise the workflows with a fake Pro Tools adapter. Pro Tools can stay closed for this command.

The optional WAV alignment utility and its Python tests use NumPy. With NumPy installed, run `python3 Tools/test_bounce_alignment.py`.

The app is created at `Build/QuickBounce V0.7.0.app` with an ad hoc signature for local use. Open Pro Tools 2025.12 or later for live integration. To preview the app with generated data, run

```sh
open -n "Build/QuickBounce V0.7.0.app" --args --demo
```
