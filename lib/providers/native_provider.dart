import 'dart:async';
import 'dart:io';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:flutter/services.dart';

class WindowsInstalledApp {
  final String name;
  final String? version;
  final String? installLocation;
  final String? uninstallString;

  WindowsInstalledApp({
    required this.name,
    this.version,
    this.installLocation,
    this.uninstallString,
  });
}

class NativeFeatures {
  static bool _systemFontLoaded = false;

  static Future<ByteData> _readFileBytes(String path) async {
    var bytes = await File(path).readAsBytes();
    return ByteData.view(bytes.buffer);
  }

  static List<WindowsInstalledApp> getWindowsInstalledApps() {
    if (!Platform.isWindows) return [];

    final apps = <WindowsInstalledApp>[];
    final registryKeys = [
      r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    ];

    for (final keyPath in registryKeys) {
      final hKey = calloc<HANDLE>();
      final lpSubKey = keyPath.toNativeUtf16();

      try {
        var result = RegOpenKeyEx(HKEY_LOCAL_MACHINE, lpSubKey, 0, KEY_READ, hKey);
        if (result == ERROR_SUCCESS) {
          final dwIndex = calloc<DWORD>();
          final lpName = calloc<Uint16>(256).cast<Utf16>();
          final lpcchName = calloc<DWORD>();

          while (true) {
            lpcchName.value = 256;
            result = RegEnumKeyEx(hKey.value, dwIndex.value, lpName, lpcchName,
                nullptr, nullptr, nullptr, nullptr);

            if (result == ERROR_SUCCESS) {
              final subKeyName = lpName.toDartString();
              final app = _getAppDetails(keyPath, subKeyName);
              if (app != null) apps.add(app);
              dwIndex.value++;
            } else {
              break;
            }
          }
          calloc.free(dwIndex);
          calloc.free(lpName);
          calloc.free(lpcchName);
        }
        RegCloseKey(hKey.value);
      } finally {
        calloc.free(hKey);
        calloc.free(lpSubKey);
      }
    }
    return apps;
  }

  static WindowsInstalledApp? _getAppDetails(String parentKey, String subKeyName) {
    final hKey = calloc<HANDLE>();
    final fullPath = '$parentKey\\$subKeyName';
    final lpSubKey = fullPath.toNativeUtf16();

    try {
      final result = RegOpenKeyEx(HKEY_LOCAL_MACHINE, lpSubKey, 0, KEY_READ, hKey);
      if (result == ERROR_SUCCESS) {
        final name = _getRegistryValue(hKey.value, 'DisplayName');
        if (name != null && name.isNotEmpty) {
          final version = _getRegistryValue(hKey.value, 'DisplayVersion');
          final location = _getRegistryValue(hKey.value, 'InstallLocation');
          final uninstall = _getRegistryValue(hKey.value, 'UninstallString');
          return WindowsInstalledApp(
            name: name,
            version: version,
            installLocation: location,
            uninstallString: uninstall,
          );
        }
      }
      return null;
    } finally {
      RegCloseKey(hKey.value);
      calloc.free(hKey);
      calloc.free(lpSubKey);
    }
  }

  static String? _getRegistryValue(int hKey, String valueName) {
    final lpValueName = valueName.toNativeUtf16();
    final lpData = calloc<Uint16>(1024).cast<Utf16>();
    final lpcbData = calloc<DWORD>();
    lpcbData.value = 1024;

    try {
      final result = RegQueryValueEx(hKey, lpValueName, nullptr, nullptr,
          lpData.cast<Uint8>(), lpcbData);
      if (result == ERROR_SUCCESS) {
        return lpData.toDartString();
      }
      return null;
    } finally {
      calloc.free(lpValueName);
      calloc.free(lpData);
      calloc.free(lpcbData);
    }
  }
}
