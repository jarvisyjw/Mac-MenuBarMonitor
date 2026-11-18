# MenuBarMonitor

MenuBarMonitor is a lightweight macOS menu bar app that shows CPU usage, memory usage, and upload and download rates. It refreshes once a second. Click the menu bar item for a breakdown or to open Activity Monitor.

## Compatibility

| Mac | macOS | Build |
| --- | --- | --- |
| Apple silicon MacBook Air, Mac mini, and other Apple silicon Macs | Sonoma 14.0 or later | Native `arm64` |
| Intel Macs that can run Sonoma or later | Sonoma 14.0 or later | Build from source on Intel for `x86_64` |

The build script targets macOS 14.0 and builds for the architecture of the current shell. Use a native Terminal session on Apple silicon. Intel runtime behavior and launch on macOS 14.0 have yet to be tested on those systems.

The app uses standard macOS APIs for system metrics and works without a battery or built-in display. Network rates include all non-loopback interfaces, including Wi-Fi and Ethernet.

## Build and run

Install the Xcode Command Line Tools if they aren't already installed.

```sh
xcode-select --install
```

From the repository root, build and launch the app.

```sh
./build.sh
open build/MenuBarMonitor.app
```

The app appears in the menu bar. To keep it in your Applications list, copy `build/MenuBarMonitor.app` to `/Applications`. The build is ad hoc signed for local use.

## License

MenuBarMonitor is available under the [MIT License](LICENSE).
