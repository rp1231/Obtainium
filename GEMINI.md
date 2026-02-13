# Gemini CLI Project Learnings - Obtainium Windows Port

## Build & Distribution
- **DLL Dependencies:** Windows Flutter plugins often compile to separate DLLs (e.g., `battery_plus_plugin.dll`). The distribution folder (`dist`) MUST include all `*.dll` files from `build\windows\x64unner\Release`, not just `flutter_windows.dll`.
- **AOT Compilation Issues:** `flutter_local_notifications_windows` (v2.0.1) has a known bug involving `NativeLaunchDetails` that prevents AOT compilation, causing Windows Release builds to fail.

## Stability & Startup
- **Global Variable Pitfall:** Avoid calling `tr()` (translations) or complex constructors (like `GitHub()`) in top-level or static variables. In Release mode, these may execute before the app is initialized, causing a silent crash before `main()` is reached. Use `get` properties instead.
- **Native Plugin Crashes:** Some plugins (like `win_toast` in our testing) can cause silent native crashes during the `RegisterPlugins` phase in the C++ runner. If the app disappears immediately and `main()` logs don't trigger, the issue is likely in `generated_plugin_registrant.cc`.

## Debugging Techniques
- **Isolation:** To debug "disappearing" executables, simplify `main.dart` to a minimal `MaterialApp` and incrementally remove plugins from `pubspec.yaml` until the app stays open.
- **Logging:** Standard `stdout`/`stderr` redirection often fails to capture early native crashes. Windows Event Viewer (`Application` log) is the best place to look for `Exception code: 0xc0000005` (Access Violation) errors.

## Project Context
- This project is a **Windows Port** of the Obtainium Android app. Focus on Windows-specific builds and behaviors.
- Always use `flutter build windows --release` for final verification.
