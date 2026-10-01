# DI Reloaded

A spiritual successor to [Disk Inventory X](http://www.derlien.com), lovingly vibe coded
for modern macOS. It's a native Swift app that shows where your disk space went as a
cushion treemap, and it's built to scan as fast as the SSD allows.

> **Status:** early development (Phase 0 done). See [PLAN.md](PLAN.md).

DI Reloaded is a from-scratch rewrite with no code from the original, which remains
the work of Tjark Derlien. This project isn't affiliated with it, just fond of it.

## Building

Requires Xcode 26+, macOS 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml`.

```sh
xcodegen generate && open DIReloaded.xcodeproj   # the app
```

Debug builds accept `-scan <path>` to start scanning at launch.

The core engine is a Swift package and can be built and tested without the app:

```sh
cd Packages/Core
swift test                                  # run the test suite
swift build -c release
.build/release/dir-bench ~                  # benchmark a scan of your home folder
.build/release/dir-bench ~ --treemap out.png
```

## License

MIT, see [LICENSE](LICENSE).
