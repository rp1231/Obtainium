// Manages state related to the list of Apps tracked by Obtainium,
// Exposes related functions such as those used to add, remove, download, and install Apps.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/io_client.dart';
import 'package:obtainium/app_sources/directAPKLink.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:http/http.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:obtainium/providers/native_provider.dart';

// Windows-focused app info
class ObtainiumPackageInfo {
  final String? packageName;
  final String? versionName;
  final int? versionCode;
  final ObtainiumApplicationInfo? applicationInfo;

  ObtainiumPackageInfo({
    this.packageName,
    this.versionName,
    this.versionCode,
    this.applicationInfo,
  });
}

class ObtainiumApplicationInfo {
  final String? name;

  ObtainiumApplicationInfo({this.name});

  Future<String?> getAppLabel() async {
    return name;
  }

  Future<Uint8List?> getAppIcon() async {
    return null;
  }
}

class AppInMemory {
  late App app;
  double? downloadProgress;
  ObtainiumPackageInfo? installedInfo;
  Uint8List? icon;

  AppInMemory(this.app, this.downloadProgress, this.installedInfo, this.icon);
  AppInMemory deepCopy() =>
      AppInMemory(app.deepCopy(), downloadProgress, installedInfo, icon);

  String get name => app.overrideName ?? app.finalName;
  String get author => app.overrideAuthor ?? app.finalAuthor;

  bool get hasMultipleSigners => false;

  List<String> get certificateHashes => [];
}

class DownloadedApk {
  String appId;
  File file;
  DownloadedApk(this.appId, this.file);
}

enum DownloadedDirType { XAPK, ZIP }

class DownloadedDir {
  String appId;
  File file;
  Directory extracted;
  DownloadedDirType type;
  DownloadedDir(this.appId, this.file, this.extracted, this.type);
}

List<String> generateStandardVersionRegExStrings() {
  var basics = [
    '[0-9]+',
    '[0-9]+\\.[0-9]+',
    '[0-9]+\\.[0-9]+\\.[0-9]+',
    '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+',
  ];
  var preSuffixes = ['-', '\\+'];
  var suffixes = ['alpha', 'beta', 'ose', '[0-9]+'];
  var finals = ['\\+[0-9]+', '[0-9]+'];
  List<String> results = [];
  for (var b in basics) {
    results.add(b);
    for (var p in preSuffixes) {
      for (var s in suffixes) {
        results.add('$b$s');
        results.add('$b$p$s');
        for (var f in finals) {
          results.add('$b$s$f');
          results.add('$b$p$s$f');
        }
      }
    }
  }
  return results;
}

List<String> standardVersionRegExStrings =
    generateStandardVersionRegExStrings();

Set<String> findStandardFormatsForVersion(String version, bool strict) {
  // If !strict, even a substring match is valid
  Set<String> results = {};
  for (var pattern in standardVersionRegExStrings) {
    if (RegExp(
      '${strict ? '^' : ''}$pattern${strict ? '\$' : ''}',
    ).hasMatch(version)) {
      results.add(pattern);
    }
  }
  return results;
}

List<String> moveStrToEnd(List<String> arr, String str, {String? strB}) {
  String? temp;
  arr.removeWhere((element) {
    bool res = element == str || element == strB;
    if (res) {
      temp = element;
    }
    return res;
  });
  if (temp != null) {
    arr = [...arr, temp!];
  }
  return arr;
}

Future<File> downloadFileWithRetry(
  String url,
  String fileName,
  bool fileNameHasExt,
  Function? onProgress,
  String destDir, {
  bool useExisting = true,
  Map<String, String>? headers,
  int retries = 3,
  bool allowInsecure = false,
  LogsProvider? logs,
}) async {
  try {
    return await downloadFile(
      url,
      fileName,
      fileNameHasExt,
      onProgress,
      destDir,
      useExisting: useExisting,
      headers: headers,
      allowInsecure: allowInsecure,
      logs: logs,
    );
  } catch (e) {
    if (retries > 0 && e is ClientException) {
      await Future.delayed(const Duration(seconds: 5));
      return await downloadFileWithRetry(
        url,
        fileName,
        fileNameHasExt,
        onProgress,
        destDir,
        useExisting: useExisting,
        headers: headers,
        retries: (retries - 1),
        allowInsecure: allowInsecure,
        logs: logs,
      );
    } else {
      rethrow;
    }
  }
}

String hashListOfLists(List<List<int>> data) {
  var bytes = utf8.encode(jsonEncode(data));
  var digest = sha256.convert(bytes);
  var hash = digest.toString();
  return hash.hashCode.toString();
}

Future<String> checkPartialDownloadHash(
  String url,
  int bytesToGrab, {
  Map<String, String>? headers,
  bool allowInsecure = false,
}) async {
  var req = Request('GET', Uri.parse(url));
  if (headers != null) {
    req.headers.addAll(headers);
  }
  req.headers[HttpHeaders.rangeHeader] = 'bytes=0-$bytesToGrab';
  var client = IOClient(createHttpClient(allowInsecure));
  var response = await client.send(req);
  if (response.statusCode < 200 || response.statusCode > 299) {
    throw ObtainiumError(response.reasonPhrase ?? tr('unexpectedError'));
  }
  List<List<int>> bytes = await response.stream.take(bytesToGrab).toList();
  return hashListOfLists(bytes);
}

Future<String?> checkETagHeader(
  String url, {
  Map<String, String>? headers,
  bool allowInsecure = false,
}) async {
  // Send the initial request but cancel it as soon as you have the headers
  var reqHeaders = headers ?? {};
  var req = Request('GET', Uri.parse(url));
  req.headers.addAll(reqHeaders);
  var client = IOClient(createHttpClient(allowInsecure));
  StreamedResponse response = await client.send(req);
  var resHeaders = response.headers;
  client.close();
  return resHeaders[HttpHeaders.etagHeader]
      ?.replaceAll('"', '')
      .hashCode
      .toString();
}

Future<String> checkPartialDownloadHashDynamic(
  String url, {
  int startingSize = 1024,
  int lowerLimit = 128,
  Map<String, String>? headers,
  bool allowInsecure = false,
}) async {
  for (int i = startingSize; i >= lowerLimit; i -= 256) {
    List<String> ab = await Future.wait([
      checkPartialDownloadHash(
        url,
        i,
        headers: headers,
        allowInsecure: allowInsecure,
      ),
      checkPartialDownloadHash(
        url,
        i,
        headers: headers,
        allowInsecure: allowInsecure,
      ),
    ]);
    if (ab[0] == ab[1]) {
      return ab[0];
    }
  }
  throw NoVersionError();
}

void deleteFile(File file) {
  try {
    file.deleteSync(recursive: true);
  } on PathAccessException catch (e) {
    throw ObtainiumError(
      tr('fileDeletionError', args: [e.path ?? tr('unknown')]),
    );
  }
}

Future<File> downloadFile(
  String url,
  String fileName,
  bool fileNameHasExt,
  Function? onProgress,
  String destDir, {
  bool useExisting = true,
  Map<String, String>? headers,
  bool allowInsecure = false,
  LogsProvider? logs,
}) async {
  // Send the initial request but cancel it as soon as you have the headers
  var reqHeaders = headers ?? {};
  var req = Request('GET', Uri.parse(url));
  req.headers.addAll(reqHeaders);
  var headersClient = IOClient(createHttpClient(allowInsecure));
  StreamedResponse headersResponse = await headersClient.send(req);
  var resHeaders = headersResponse.headers;

  // Use the headers to decide what the file extension is, and
  // whether it supports partial downloads (range request), and
  // what the total size of the file is (if provided)
  String ext = resHeaders['content-disposition']?.split('.').last ?? 'exe';
  if (ext.endsWith('"') || ext.endsWith("other")) {
    ext = ext.substring(0, ext.length - 1);
  }
  if (((Uri.tryParse(url)?.path ?? url).toLowerCase().endsWith('.exe') ||
          ext == 'attachment') &&
      ext != 'exe') {
    ext = 'exe';
  }
  fileName = fileNameHasExt
      ? fileName
      : fileName.split('/').last; // Ensure the fileName is a file name
  File downloadedFile = File('$destDir/$fileName.$ext');
  if (fileNameHasExt) {
    // If the user says the filename already has an ext, ignore whatever you inferred from above
    downloadedFile = File('$destDir/$fileName');
  }

  bool rangeFeatureEnabled = false;
  if (resHeaders['accept-ranges']?.isNotEmpty == true) {
    rangeFeatureEnabled =
        resHeaders['accept-ranges']?.trim().toLowerCase() == 'bytes';
  }
  headersClient.close();

  // If you have an existing file that is usable,
  // decide whether you can use it (either return full or resume partial)
  var fullContentLength = headersResponse.contentLength;
  if (useExisting && downloadedFile.existsSync()) {
    var length = downloadedFile.lengthSync();
    if (fullContentLength == null || !rangeFeatureEnabled) {
      // If there is no content length reported, assume it the existing file is fully downloaded
      // Also if the range feature is not supported, don't trust the content length if any (#1542)
      return downloadedFile;
    } else {
      // Check if resume needed/possible
      if (length == fullContentLength) {
        return downloadedFile;
      }
      if (length > fullContentLength) {
        useExisting = false;
      }
    }
  }

  // Download to a '.temp' file (to distinguish btn. complete/incomplete files)
  File tempDownloadedFile = File('${downloadedFile.path}.part');

  // If there is already a temp file, a download may already be in progress - account for this (see #2073)
  bool tempFileExists = tempDownloadedFile.existsSync();
  if (tempFileExists && useExisting) {
    logs?.add(
      'Partial download exists - will wait: ${tempDownloadedFile.uri.pathSegments.last}',
    );
    bool isDownloading = true;
    int currentTempFileSize = await tempDownloadedFile.length();
    bool shouldReturn = false;
    while (isDownloading) {
      await Future.delayed(Duration(seconds: 7));
      if (tempDownloadedFile.existsSync()) {
        int newTempFileSize = await tempDownloadedFile.length();
        if (newTempFileSize > currentTempFileSize) {
          currentTempFileSize = newTempFileSize;
          logs?.add(
            'Existing partial download still in progress: ${tempDownloadedFile.uri.pathSegments.last}',
          );
        } else {
          logs?.add(
            'Ignoring existing partial download: ${tempDownloadedFile.uri.pathSegments.last}',
          );
          break;
        }
      } else {
        shouldReturn = downloadedFile.existsSync();
      }
    }
    if (shouldReturn) {
      logs?.add(
        'Existing partial download completed - not repeating: ${tempDownloadedFile.uri.pathSegments.last}',
      );
      return downloadedFile;
    } else {
      logs?.add(
        'Existing partial download not in progress: ${tempDownloadedFile.uri.pathSegments.last}',
      );
    }
  }

  // If the range feature is not available (or you need to start a ranged req from 0),
  // complete the already-started request, else cancel it and start a ranged request,
  // and open the file for writing in the appropriate mode
  var targetFileLength = useExisting && tempDownloadedFile.existsSync()
      ? tempDownloadedFile.lengthSync()
      : null;
  int rangeStart = targetFileLength ?? 0;
  IOSink? sink;
  req = Request('GET', Uri.parse(url));
  req.headers.addAll(reqHeaders);
  if (rangeFeatureEnabled && fullContentLength != null && rangeStart > 0) {
    reqHeaders.addAll({'range': 'bytes=$rangeStart-${fullContentLength - 1}'});
    sink = tempDownloadedFile.openWrite(mode: FileMode.writeOnlyAppend);
  } else if (tempDownloadedFile.existsSync()) {
    deleteFile(tempDownloadedFile);
  }
  var responseWithClient = await sourceRequestStreamResponse(
    'GET',
    url,
    reqHeaders,
    {},
  );
  HttpClient responseClient = responseWithClient.value.key;
  HttpClientResponse response = responseWithClient.value.value;
  sink ??= tempDownloadedFile.openWrite(mode: FileMode.writeOnly);

  // Perform the download
  var received = 0;
  double? progress;
  DateTime? lastProgressUpdate; // Track last progress update time
  if (rangeStart > 0 && fullContentLength != null) {
    received = rangeStart;
  }
  const downloadUIUpdateInterval = Duration(milliseconds: 500);
  const downloadBufferSize = 32 * 1024; // 32KB
  final downloadBuffer = BytesBuilder();
  await response
      .asBroadcastStream()
      .map((chunk) {
        received += chunk.length;
        final now = DateTime.now();
        if (onProgress != null &&
            (lastProgressUpdate == null ||
                now.difference(lastProgressUpdate!) >=
                    downloadUIUpdateInterval)) {
          progress = fullContentLength != null
              ? clampDouble((received / fullContentLength) * 100, 0, 100)
              : 30;
          onProgress(progress);
          lastProgressUpdate = now;
        }
        return chunk;
      })
      .transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (List<int> data, EventSink<List<int>> s) {
            downloadBuffer.add(data);
            if (downloadBuffer.length >= downloadBufferSize) {
              s.add(downloadBuffer.takeBytes());
            }
          },
          handleDone: (EventSink<List<int>> s) {
            if (downloadBuffer.isNotEmpty) {
              s.add(downloadBuffer.takeBytes());
            }
            s.close();
          },
        ),
      )
      .pipe(sink);
  await sink.close();
  progress = null;
  if (onProgress != null) {
    onProgress(progress);
  }
  if (response.statusCode < 200 || response.statusCode > 299) {
    deleteFile(tempDownloadedFile);
    throw response.reasonPhrase;
  }
  if (tempDownloadedFile.existsSync()) {
    tempDownloadedFile.renameSync(downloadedFile.path);
  }
  responseClient.close();
  return downloadedFile;
}

Future<List<ObtainiumPackageInfo>> getAllInstalledInfo() async {
  final windowsApps = NativeFeatures.getWindowsInstalledApps();
  return windowsApps
      .map((app) => ObtainiumPackageInfo(
            packageName: app.name,
            versionName: app.version,
            applicationInfo: ObtainiumApplicationInfo(
              name: app.name,
            ),
          ))
      .toList();
}

Future<ObtainiumPackageInfo?> getInstalledInfo(
  String? packageName, {
  bool printErr = true,
}) async {
  if (packageName != null) {
    final windowsApps = NativeFeatures.getWindowsInstalledApps();
    try {
      final app = windowsApps.firstWhere((a) => a.name == packageName);
      return ObtainiumPackageInfo(
          packageName: app.name,
          versionName: app.version,
          applicationInfo: ObtainiumApplicationInfo(
            name: app.name,
          ));
    } catch (e) {
      // Not found
    }
  }
  return null;
}

Future<Directory> getAppStorageDir() async {
  return await getApplicationSupportDirectory();
}

class AppsProvider with ChangeNotifier {
  Map<String, AppInMemory> apps = {};
  bool loadingApps = false;
  bool gettingUpdates = false;
  LogsProvider logs = LogsProvider();

  bool isForeground = true;
  late Directory APKDir;
  late Directory iconsCacheDir;
  late SettingsProvider settingsProvider = SettingsProvider();

  Iterable<AppInMemory> getAppValues() => apps.values.map((a) => a.deepCopy());

  AppsProvider({isBg = false}) {
    () async {
      await settingsProvider.initializeSettings();
      final storageDir = await getAppStorageDir();
      APKDir = Directory('${storageDir.path}/downloads');
      if (!APKDir.existsSync()) {
        APKDir.createSync(recursive: true);
      }
      iconsCacheDir = Directory('${storageDir.path}/icons');
      if (!iconsCacheDir.existsSync()) {
        iconsCacheDir.createSync(recursive: true);
      }
      if (!isBg) {
        await loadApps();
        var cutoff = DateTime.now().subtract(const Duration(days: 7));
        APKDir.listSync()
            .where((element) => element.statSync().modified.isBefore(cutoff))
            .forEach((partialApk) {
              if (!areDownloadsRunning()) {
                partialApk.delete(recursive: true);
              }
            });
      }
    }();
  }

  Future<File> handleAPKIDChange(
    App app,
    ObtainiumPackageInfo newInfo,
    File downloadedFile,
    String downloadUrl,
  ) async {
    var isTempIdBool = isTempId(app);
    if (app.id != newInfo.packageName) {
      if (apps[app.id] != null && !isTempIdBool && !app.allowIdChange) {
        throw IDChangedError(newInfo.packageName!);
      }
      var idChangeWasAllowed = app.allowIdChange;
      app.allowIdChange = false;
      var originalAppId = app.id;
      app.id = newInfo.packageName!;
      downloadedFile = downloadedFile.renameSync(
        '${downloadedFile.parent.path}/${app.id}-${downloadUrl.hashCode}.${downloadedFile.path.split('.').last}',
      );
      if (apps[originalAppId] != null) {
        await removeApps([originalAppId]);
        await saveApps([
          app,
        ], onlyIfExists: !isTempIdBool && !idChangeWasAllowed);
      }
    }
    return downloadedFile;
  }

  Future<Object> downloadApp(
    App app,
    BuildContext? context, {
    NotificationsProvider? notificationsProvider,
    bool useExisting = true,
  }) async {
    var notifId = DownloadNotification(app.finalName, 0).id;
    if (apps[app.id] != null) {
      apps[app.id]!.downloadProgress = 0;
      notifyListeners();
    }
    try {
      AppSource source = SourceProvider().getSource(
        app.url,
        overrideSource: app.overrideSource,
      );
      var additionalSettingsPlusSourceConfig = {
        ...app.additionalSettings,
        ...(await source.getSourceConfigValues(
          app.additionalSettings,
          settingsProvider,
        )),
      };
      String downloadUrl = await source.assetUrlPrefetchModifier(
        await source.generalReqPrefetchModifier(
          app.apkUrls[app.preferredApkIndex].value,
          additionalSettingsPlusSourceConfig,
        ),
        app.url,
        additionalSettingsPlusSourceConfig,
      );
      var notif = DownloadNotification(app.finalName, 100);
      notificationsProvider?.cancel(notif.id);
      int? prevProg;
      var fileNameNoExt = '${app.id}-${downloadUrl.hashCode}';
      if (source.urlsAlwaysHaveExtension) {
        fileNameNoExt =
            '$fileNameNoExt.${app.apkUrls[app.preferredApkIndex].key.split('.').last}';
      }
      var headers = await source.getRequestHeaders(
        app.additionalSettings,
        downloadUrl,
        forAPKDownload: true,
      );
      var downloadedFile = await downloadFileWithRetry(
        downloadUrl,
        fileNameNoExt,
        source.urlsAlwaysHaveExtension,
        headers: headers,
        (double? progress) {
          int? prog = progress?.ceil();
          if (apps[app.id] != null) {
            apps[app.id]!.downloadProgress = progress;
            notifyListeners();
          }
          notif = DownloadNotification(app.finalName, prog ?? 100);
          if (prog != null && prevProg != prog) {
            notificationsProvider?.notify(notif);
          }
          prevProg = prog;
        },
        APKDir.path,
        useExisting: useExisting,
        allowInsecure: app.additionalSettings['allowInsecure'] == true,
        logs: logs,
      );
      if (apps[app.id] != null) {
        apps[app.id]!.downloadProgress = -1;
        notifyListeners();
        notif = DownloadNotification(app.finalName, -1);
        notificationsProvider?.notify(notif);
      }
      
      for (var file in downloadedFile.parent.listSync()) {
        var fn = file.path.split('/').last;
        if (fn.startsWith('${app.id}-') &&
            FileSystemEntity.isFileSync(file.path) &&
            file.path != downloadedFile.path) {
          file.delete(recursive: true);
        }
      }
      return DownloadedApk(app.id, downloadedFile);
    } finally {
      notificationsProvider?.cancel(notifId);
      if (apps[app.id] != null) {
        apps[app.id]!.downloadProgress = null;
        notifyListeners();
      }
    }
  }

  bool areDownloadsRunning() => apps.values
      .where((element) => element.downloadProgress != null)
      .isNotEmpty;

  Future<void> unzipFile(String filePath, String destinationPath) async {
    await ZipFile.extractToDirectory(
      zipFile: File(filePath),
      destinationDir: Directory(destinationPath),
    );
  }

  Future<bool> installWindowsApp(DownloadedApk file) async {
    final extension = file.file.path.split('.').last.toLowerCase();
    if (extension == 'exe' || extension == 'msi') {
      final result = await Process.run(file.file.path, []);
      if (result.exitCode != 0) {
        throw ObtainiumError('Installation failed with exit code ${result.exitCode}');
      }
      return true;
    } else if (extension == 'zip') {
      final result = await Process.run('explorer.exe', [file.file.path]);
      return result.exitCode == 0;
    }
    throw ObtainiumError('Unsupported file type: $extension');
  }

  Future<bool> installApk(
    DownloadedApk file,
    BuildContext? firstTimeWithContext, {
    bool needsBGWorkaround = false,
    bool shizukuPretendToBeGooglePlay = false,
    List<DownloadedApk> additionalAPKs = const [],
  }) async {
    bool success = await installWindowsApp(file);
    if (success) {
      apps[file.appId]!.app.installedVersion =
          apps[file.appId]!.app.latestVersion;
      file.file.delete(recursive: true);
      await saveApps([apps[file.appId]!.app]);
    }
    return success;
  }

  Future<void> uninstallApp(String appId) async {
  }

  Future<MapEntry<String, String>?> confirmAppFileUrl(
    App app,
    BuildContext? context,
    bool pickAnyAsset, {
    bool evenIfSingleChoice = false,
  }) async {
    var urlsToSelectFrom = app.apkUrls;
    if (pickAnyAsset) {
      urlsToSelectFrom = [...urlsToSelectFrom, ...app.otherAssetUrls];
    }
    MapEntry<String, String>? appFileUrl =
        urlsToSelectFrom[app.preferredApkIndex >= 0
            ? app.preferredApkIndex
            : 0];

    if ((urlsToSelectFrom.length > 1 || evenIfSingleChoice) &&
        context != null) {
      appFileUrl = await showDialog(
        context: context,
        builder: (BuildContext ctx) {
          return AppFilePicker(
            app: app,
            initVal: appFileUrl,
            archs: ['x64', 'arm64', 'x86'],
            pickAnyAsset: pickAnyAsset,
          );
        },
      );
    }
    return appFileUrl;
  }

  Future<List<String>> downloadAndInstallLatestApps(
    List<String> appIds,
    BuildContext? context, {
    NotificationsProvider? notificationsProvider,
    bool forceParallelDownloads = false,
    bool useExisting = true,
  }) async {
    notificationsProvider =
        notificationsProvider ?? context?.read<NotificationsProvider>();
    List<String> appsToInstall = [];
    List<String> trackOnlyAppsToUpdate = [];
    for (var id in appIds) {
      if (apps[id] == null) {
        throw ObtainiumError(tr('appNotFound'));
      }
      MapEntry<String, String>? apkUrl;
      var trackOnly = apps[id]!.app.additionalSettings['trackOnly'] == true;
      var refreshBeforeDownload =
          apps[id]!.app.additionalSettings['refreshBeforeDownload'] == true ||
          apps[id]!.app.apkUrls.isNotEmpty &&
              apps[id]!.app.apkUrls.first.value == 'placeholder';
      if (refreshBeforeDownload) {
        await checkUpdate(apps[id]!.app.id);
      }
      if (!trackOnly) {
        apkUrl = await confirmAppFileUrl(apps[id]!.app, context, false);
      }
      if (apkUrl != null) {
        int urlInd = apps[id]!.app.apkUrls
            .map((e) => e.value)
            .toList()
            .indexOf(apkUrl.value);
        if (urlInd >= 0 && urlInd != apps[id]!.app.preferredApkIndex) {
          apps[id]!.app.preferredApkIndex = urlInd;
          await saveApps([apps[id]!.app]);
        }
        appsToInstall.add(id);
      }
      if (trackOnly) {
        trackOnlyAppsToUpdate.add(id);
      }
    }
    saveApps(
      trackOnlyAppsToUpdate.map((e) {
        var a = apps[e]!.app;
        a.installedVersion = a.latestVersion;
        return a;
      }).toList(),
    );

    List<String> installedIds = [];

    Future<void> installFn(
      String id,
      DownloadedApk? downloadedFile,
    ) async {
      apps[id]?.downloadProgress = -1;
      notifyListeners();
      try {
        bool sayInstalled = true;
        if (downloadedFile != null) {
          sayInstalled = await installApk(
            downloadedFile,
            null,
          );
        }
        if (sayInstalled) {
          installedIds.add(id);
          notificationsProvider?.cancel(UpdateNotification([]).id);
        }
      } finally {
        apps[id]?.downloadProgress = null;
        notifyListeners();
      }
    }

    Future<Map<Object?, Object?>> downloadFn(
      String id, {
      bool skipInstalls = false,
    }) async {
      DownloadedApk? downloadedFile;
      try {
        var downloadedArtifact =
            await downloadApp(
              apps[id]!.app,
              context,
              notificationsProvider: notificationsProvider,
              useExisting: useExisting,
            );
        if (downloadedArtifact is DownloadedApk) {
          downloadedFile = downloadedArtifact;
        }
        id = downloadedFile!.appId;
      } catch (e) {
        logs.add('Download error for $id: ${e.toString()}');
      }
      return {
        'id': id,
        'downloadedFile': downloadedFile,
      };
    }

    List<Map<Object?, Object?>> downloadResults = [];
    if (forceParallelDownloads || !settingsProvider.parallelDownloads) {
      for (var id in appsToInstall) {
        downloadResults.add(await downloadFn(id));
      }
    } else {
      downloadResults = await Future.wait(
        appsToInstall.map((id) => downloadFn(id, skipInstalls: true)),
      );
    }
    for (var res in downloadResults) {
      if (res['downloadedFile'] != null) {
        try {
          await installFn(
            res['id'] as String,
            res['downloadedFile'] as DownloadedApk?,
          );
        } catch (e) {
          var id = res['id'] as String;
          logs.add('Install error for $id: ${e.toString()}');
        }
      }
    }

    return installedIds;
  }

  Future<List<String>> downloadAppAssets(
    List<String> appIds,
    BuildContext context, {
    bool forceParallelDownloads = false,
  }) async {
    NotificationsProvider notificationsProvider = context
        .read<NotificationsProvider>();
    List<MapEntry<MapEntry<String, String>, App>> filesToDownload = [];
    for (var id in appIds) {
      if (apps[id] == null) {
        throw ObtainiumError(tr('appNotFound'));
      }
      MapEntry<String, String>? fileUrl;
      var refreshBeforeDownload =
          apps[id]!.app.additionalSettings['refreshBeforeDownload'] == true ||
          apps[id]!.app.apkUrls.isNotEmpty &&
              apps[id]!.app.apkUrls.first.value == 'placeholder';
      if (refreshBeforeDownload) {
        await checkUpdate(apps[id]!.app.id);
      }
      if (apps[id]!.app.apkUrls.isNotEmpty ||
          apps[id]!.app.otherAssetUrls.isNotEmpty) {
        MapEntry<String, String>? tempFileUrl = await confirmAppFileUrl(
          apps[id]!.app,
          context,
          true,
          evenIfSingleChoice: true,
        );
        if (tempFileUrl != null) {
          var s = SourceProvider().getSource(
            apps[id]!.app.url,
            overrideSource: apps[id]!.app.overrideSource,
          );
          var additionalSettingsPlusSourceConfig = {
            ...apps[id]!.app.additionalSettings,
            ...(await s.getSourceConfigValues(
              apps[id]!.app.additionalSettings,
              settingsProvider,
            )),
          };
          fileUrl = MapEntry(
            tempFileUrl.key,
            await s.assetUrlPrefetchModifier(
              await s.generalReqPrefetchModifier(
                tempFileUrl.value,
                additionalSettingsPlusSourceConfig,
              ),
              apps[id]!.app.url,
              additionalSettingsPlusSourceConfig,
            ),
          );
        }
      }
      if (fileUrl != null) {
        filesToDownload.add(MapEntry(fileUrl, apps[id]!.app));
      }
    }

    List<String> downloadedIds = [];

    Future<void> downloadFn(MapEntry<String, String> fileUrl, App app) async {
      try {
        String downloadPath = '${(await getAppStorageDir()).path}/Download';
        await downloadFile(
          fileUrl.value,
          fileUrl.key,
          true,
          (double? progress) {
            notificationsProvider.notify(
              DownloadNotification(fileUrl.key, progress?.ceil() ?? 0),
            );
          },
          downloadPath,
          headers: await SourceProvider()
              .getSource(app.url, overrideSource: app.overrideSource)
              .getRequestHeaders(
                app.additionalSettings,
                fileUrl.value,
                forAPKDownload: fileUrl.key.endsWith('.exe') ? true : false,
              ),
          useExisting: false,
          allowInsecure: app.additionalSettings['allowInsecure'] == true,
          logs: logs,
        );
        notificationsProvider.notify(
          DownloadedNotification(fileUrl.key, fileUrl.value),
        );
      } catch (e) {
        logs.add('Download error for ${fileUrl.key}: ${e.toString()}');
      } finally {
        notificationsProvider.cancel(DownloadNotification(fileUrl.key, 0).id);
      }
    }

    if (forceParallelDownloads || !settingsProvider.parallelDownloads) {
      for (var urlWithApp in filesToDownload) {
        await downloadFn(urlWithApp.key, urlWithApp.value);
      }
    } else {
      await Future.wait(
        filesToDownload.map(
          (urlWithApp) => downloadFn(urlWithApp.key, urlWithApp.value),
        ),
      );
    }
    return downloadedIds;
  }

  Future<Directory> getAppsDir() async {
    Directory appsDir = Directory(
      '${(await getAppStorageDir()).path}/app_data',
    );
    if (!appsDir.existsSync()) {
      appsDir.createSync(recursive: true);
    }
    return appsDir;
  }

  bool isVersionDetectionPossible(AppInMemory? app) {
    if (app?.app == null) {
      return false;
    }
    var source = SourceProvider().getSource(
      app!.app.url,
      overrideSource: app.app.overrideSource,
    );
    var naiveStandardVersionDetection =
        app.app.additionalSettings['naiveStandardVersionDetection'] == true ||
        source.naiveStandardVersionDetection;
    String? realInstalledVersion = app.installedInfo?.versionName;
    bool isHTMLWithNoVersionDetection =
        (source.runtimeType == HTML().runtimeType &&
        (app.app.additionalSettings['versionExtractionRegEx'] as String?)
                ?.isNotEmpty !=
            true);
    bool isDirectAPKLink = source.runtimeType == DirectAPKLink().runtimeType;
    return app.app.additionalSettings['trackOnly'] != true &&
        app.app.additionalSettings['releaseDateAsVersion'] != true &&
        !isHTMLWithNoVersionDetection &&
        !isDirectAPKLink &&
        realInstalledVersion != null &&
        app.app.installedVersion != null &&
        (reconcileVersionDifferences(
                  realInstalledVersion,
                  app.app.installedVersion!,
                ) !=
                null ||
            naiveStandardVersionDetection);
  }

  App? getCorrectedInstallStatusAppIfPossible(
    App app,
    ObtainiumPackageInfo? installedInfo,
  ) {
    var modded = false;
    var trackOnly = app.additionalSettings['trackOnly'] == true;
    var versionDetectionIsStandard =
        app.additionalSettings['versionDetection'] == true;
    var naiveStandardVersionDetection =
        app.additionalSettings['naiveStandardVersionDetection'] == true ||
        SourceProvider()
            .getSource(app.url, overrideSource: app.overrideSource)
            .naiveStandardVersionDetection;
    String? realInstalledVersion = installedInfo?.versionName;
    if (installedInfo == null && app.installedVersion != null && !trackOnly) {
      app.installedVersion = null;
      modded = true;
    } else if (realInstalledVersion != null && app.installedVersion == null) {
      app.installedVersion = realInstalledVersion;
      modded = true;
    }
    if (realInstalledVersion != null &&
        realInstalledVersion != app.installedVersion &&
        versionDetectionIsStandard) {
      var correctedInstalledVersion = reconcileVersionDifferences(
        realInstalledVersion,
        app.installedVersion!,
      );
      if (correctedInstalledVersion?.key == false) {
        app.installedVersion = correctedInstalledVersion!.value;
        modded = true;
      } else if (naiveStandardVersionDetection) {
        app.installedVersion = realInstalledVersion;
        modded = true;
      }
    }
    if (app.installedVersion != null &&
        app.installedVersion != app.latestVersion &&
        versionDetectionIsStandard) {
      var correctedInstalledVersion = reconcileVersionDifferences(
        app.installedVersion!,
        app.latestVersion,
      );
      if (correctedInstalledVersion?.key == true) {
        app.installedVersion = correctedInstalledVersion!.value;
        modded = true;
      }
    }
    if (installedInfo != null &&
        versionDetectionIsStandard &&
        !isVersionDetectionPossible(
          AppInMemory(app, null, installedInfo, null),
        )) {
      app.additionalSettings['versionDetection'] = false;
      app.installedVersion = app.latestVersion;
      logs.add('Could not reconcile version formats for: ${app.id}');
      modded = true;
    }

    return modded ? app : null;
  }

  MapEntry<bool, String>? reconcileVersionDifferences(
    String templateVersion,
    String comparisonVersion,
  ) {
    var templateVersionFormats = findStandardFormatsForVersion(
      templateVersion,
      true,
    );
    var comparisonVersionFormats = findStandardFormatsForVersion(
      comparisonVersion,
      true,
    );
    if (comparisonVersionFormats.isEmpty) {
      comparisonVersionFormats = findStandardFormatsForVersion(
        comparisonVersion,
        false,
      );
    }
    var commonStandardFormats = templateVersionFormats.intersection(
      comparisonVersionFormats,
    );
    if (commonStandardFormats.isEmpty) {
      return null;
    }
    for (String pattern in commonStandardFormats) {
      if (doStringsMatchUnderRegEx(
        pattern,
        comparisonVersion,
        templateVersion,
      )) {
        return MapEntry(true, comparisonVersion);
      }
    }
    return MapEntry(false, templateVersion);
  }

  bool doStringsMatchUnderRegEx(String pattern, String value1, String value2) {
    var r = RegExp(pattern);
    var m1 = r.firstMatch(value1);
    var m2 = r.firstMatch(value2);
    return m1 != null && m2 != null
        ? value1.substring(m1.start, m1.end) ==
              value2.substring(m2.start, m2.end)
        : false;
  }

  Future<void> loadApps({String? singleId}) async {
    while (loadingApps) {
      await Future.delayed(const Duration(microseconds: 1));
    }
    loadingApps = true;
    notifyListeners();
    var sp = SourceProvider();
    var installedAppsData = await getAllInstalledInfo();
    List<String> removedAppIds = [];
    await Future.wait(
      (await getAppsDir())
          .listSync()
          .map((item) async {
            App? app;
            if (item.path.toLowerCase().endsWith('.json') &&
                (singleId == null ||
                    item.path.split('/').last.toLowerCase() ==
                        '${singleId.toLowerCase()}.json')) {
              try {
                app = App.fromJson(
                  jsonDecode(File(item.path).readAsStringSync()),
                );
              } catch (err) {
                if (err is FormatException) {
                  logs.add(
                    'Corrupt JSON when loading App (will be ignored): $err',
                  );
                  item.renameSync('${item.path}.corrupt');
                } else {
                  rethrow;
                }
              }
            }
            if (app != null) {
              apps.update(
                app.id,
                (value) => AppInMemory(
                  app!,
                  value.downloadProgress,
                  value.installedInfo,
                  value.icon,
                ),
                ifAbsent: () => AppInMemory(app!, null, null, null),
              );
              notifyListeners();
              try {
                sp.getSource(app.url, overrideSource: app.overrideSource);
                ObtainiumPackageInfo? installedInfo;
                try {
                  installedInfo = installedAppsData.firstWhere(
                    (i) => i.packageName == app!.id,
                  );
                } catch (e) {
                }
                var moddedApp = getCorrectedInstallStatusAppIfPossible(
                  app,
                  installedInfo,
                );
                if (moddedApp != null) {
                  app = moddedApp;
                  if (moddedApp.installedVersion == null) {
                    removedAppIds.add(moddedApp.id);
                  }
                }
                apps.update(
                  app.id,
                  (value) => AppInMemory(
                    app!,
                    value.downloadProgress,
                    installedInfo,
                    value.icon,
                  ),
                  ifAbsent: () => AppInMemory(app!, null, installedInfo, null),
                );
                notifyListeners();
              } catch (e) {
                logs.add('Error loading app ${app!.id}: ${e.toString()}');
              }
            }
          }),
    );
    if (removedAppIds.isNotEmpty) {
      if (settingsProvider.removeOnExternalUninstall) {
        await removeApps(removedAppIds);
      }
    }
    loadingApps = false;
    notifyListeners();
  }

  Future<void> updateAppIcon(String? appId, {bool ignoreCache = false}) async {
    if (apps[appId]?.icon == null) {
      var cachedIcon = File('${iconsCacheDir.path}/$appId.png');
      var alreadyCached = cachedIcon.existsSync() && !ignoreCache;
      var icon = alreadyCached
          ? (await cachedIcon.readAsBytes())
          : (await apps[appId]?.installedInfo?.applicationInfo?.getAppIcon());
      if (icon != null && !alreadyCached) {
        cachedIcon.writeAsBytes(icon.toList());
      }
      if (icon != null) {
        apps.update(
          apps[appId]!.app.id,
          (value) => AppInMemory(
            apps[appId]!.app,
            value.downloadProgress,
            value.installedInfo,
            icon,
          ),
          ifAbsent: () => AppInMemory(
            apps[appId]!.app,
            null,
            apps[appId]?.installedInfo,
            icon,
          ),
        );
        notifyListeners();
      }
    }
  }

  Future<void> saveApps(
    List<App> apps, {
    bool attemptToCorrectInstallStatus = true,
    bool onlyIfExists = true,
  }) async {
    await Future.wait(
      apps.map((a) async {
        var app = a.deepCopy();
        ObtainiumPackageInfo? info = await getInstalledInfo(app.id);
        var icon = await info?.applicationInfo?.getAppIcon();
        app.name = await (info?.applicationInfo?.getAppLabel()) ?? app.name;
        if (attemptToCorrectInstallStatus) {
          app = getCorrectedInstallStatusAppIfPossible(app, info) ?? app;
        }
        if (!onlyIfExists || this.apps.containsKey(app.id)) {
          String filePath = '${(await getAppsDir()).path}/${app.id}.json';
          File(
            '$filePath.tmp',
          ).writeAsStringSync(jsonEncode(app.toJson()));
          File('$filePath.tmp').renameSync(filePath);
        }
        try {
          this.apps.update(
            app.id,
            (value) => AppInMemory(app, value.downloadProgress, info, icon),
            ifAbsent: onlyIfExists
                ? null
                : () => AppInMemory(app, null, info, icon),
          );
        } catch (e) {
          if (e is! ArgumentError || e.name != 'key') {
            rethrow;
          }
        }
      }),
    );
    notifyListeners();
    export(isAuto: true);
  }

  Future<void> removeApps(List<String> appIds) async {
    var apkFiles = APKDir.listSync();
    await Future.wait(
      appIds.map((appId) async {
        File file = File('${(await getAppsDir()).path}/$appId.json');
        if (file.existsSync()) {
          deleteFile(file);
        }
        apkFiles
            .where(
              (element) => element.path.split('/').last.startsWith('$appId-'),
            )
            .forEach((element) {
              element.delete(recursive: true);
            });
        if (apps.containsKey(appId)) {
          apps.remove(appId);
        }
      }),
    );
    if (appIds.isNotEmpty) {
      notifyListeners();
      export(isAuto: true);
    }
  }

  Future<bool> removeAppsWithModal(BuildContext context, List<App> apps) async {
    var values = await showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return GeneratedFormModal(
          primaryActionColour: Theme.of(context).colorScheme.error,
          title: plural('removeAppQuestion', apps.length),
          items: [
            [
              GeneratedFormSwitch(
                'rmAppEntry',
                label: tr('removeFromObtainium'),
                defaultValue: true,
              ),
            ],
          ],
          initValid: true,
        );
      },
    );
    if (values != null) {
      bool remove = values['rmAppEntry'] == true;
      if (remove) {
        await removeApps(apps.map((e) => e.id).toList());
      }
      return remove;
    }
    return false;
  }

  void addMissingCategories(SettingsProvider settingsProvider) {
    var cats = settingsProvider.categories;
    apps.forEach((key, value) {
      for (var c in value.app.categories) {
        if (!cats.containsKey(c)) {
          cats[c] = generateRandomLightColor().value;
        }
      }
    });
    settingsProvider.setCategories(cats, appsProvider: this);
  }

  Future<App?> checkUpdate(String appId) async {
    App? currentApp = apps[appId]!.app;
    SourceProvider sourceProvider = SourceProvider();
    App newApp = await sourceProvider.getApp(
      sourceProvider.getSource(
        currentApp.url,
        overrideSource: currentApp.overrideSource,
      ),
      currentApp.url,
      currentApp.additionalSettings,
      currentApp: currentApp,
    );
    if (currentApp.preferredApkIndex < newApp.apkUrls.length) {
      newApp.preferredApkIndex = currentApp.preferredApkIndex;
    }
    await saveApps([newApp]);
    return newApp.latestVersion != currentApp.latestVersion ? newApp : null;
  }

  List<String> getAppsSortedByUpdateCheckTime({
    DateTime? ignoreAppsCheckedAfter,
    bool onlyCheckInstalledOrTrackOnlyApps = false,
  }) {
    List<String> appIds = apps.values
        .where(
          (app) =>
              app.app.lastUpdateCheck == null ||
              ignoreAppsCheckedAfter == null ||
              app.app.lastUpdateCheck!.isBefore(ignoreAppsCheckedAfter),
        )
        .where((app) {
          if (!onlyCheckInstalledOrTrackOnlyApps) {
            return true;
          } else {
            return app.app.installedVersion != null ||
                app.app.additionalSettings['trackOnly'] == true;
          }
        })
        .map((e) => e.app.id)
        .toList();
    appIds.sort(
      (a, b) =>
          (apps[a]!.app.lastUpdateCheck ??
                  DateTime.fromMicrosecondsSinceEpoch(0))
              .compareTo(
                apps[b]!.app.lastUpdateCheck ??
                    DateTime.fromMicrosecondsSinceEpoch(0),
              ),
    );
    return appIds;
  }

  Future<List<App>> checkUpdates({
    DateTime? ignoreAppsCheckedAfter,
    bool throwErrorsForRetry = false,
    List<String>? specificIds,
    SettingsProvider? sp,
  }) async {
    SettingsProvider settingsProvider = sp ?? this.settingsProvider;
    List<App> updates = [];
    if (!gettingUpdates) {
      gettingUpdates = true;
      try {
        List<String> appIds = getAppsSortedByUpdateCheckTime(
          ignoreAppsCheckedAfter: ignoreAppsCheckedAfter,
          onlyCheckInstalledOrTrackOnlyApps:
              settingsProvider.onlyCheckInstalledOrTrackOnlyApps,
        );
        if (specificIds != null) {
          appIds = appIds.where((aId) => specificIds.contains(aId)).toList();
        }
        notifyListeners();
        for (var id in appIds) {
          try {
            App? update = await checkUpdate(id);
            if (update != null) {
              updates.add(update);
            }
          } catch (e) {
            logs.add('Error checking update for $id: ${e.toString()}');
          }
        }
      } finally {
        gettingUpdates = false;
        notifyListeners();
      }
    }
    return updates;
  }

  Future<MapEntry<List<App>, List<String>>> import(String json) async {
    Map<String, dynamic> data = jsonDecode(json);
    List<dynamic> appsJson = data['apps'];
    List<App> apps = appsJson.map((e) => App.fromJson(e)).toList();
    List<String> addedIds = [];
    for (var app in apps) {
      if (!this.apps.containsKey(app.id)) {
        await saveApps([app], onlyIfExists: false);
        addedIds.add(app.id);
      }
    }
    return MapEntry(apps, addedIds);
  }

  Future<String?> export({
    bool isAuto = false,
    bool pickOnly = false,
    SettingsProvider? sp,
  }) async {
    return null;
  }

  void togglePinned(String appId) {
    if (apps.containsKey(appId)) {
      apps[appId]!.app.pinned = !apps[appId]!.app.pinned;
      saveApps([apps[appId]!.app]);
    }
  }

  Future<List<List<dynamic>>> addAppsByURL(
    List<String> urls, {
    AppSource? sourceOverride,
  }) async {
    List<dynamic> results = await SourceProvider().getAppsByURLNaive(
      urls,
      alreadyAddedUrls: apps.values.map((e) => e.app.url).toList(),
      sourceOverride: sourceOverride,
    );
    List<App> pps = results[0];
    Map<String, dynamic> errorsMap = results[1];
    for (var app in pps) {
      if (!apps.containsKey(app.id)) {
        await saveApps([app], onlyIfExists: false);
      }
    }
    return [
      pps.map((e) => e.id).toList(),
      errorsMap.entries.map((e) => [e.key, e.value.toString()]).toList(),
    ];
  }

  List<App> findExistingUpdates({
    bool installedOnly = false,
    bool nonInstalledOnly = false,
  }) {
    return apps.values
        .where((a) {
          if (installedOnly && a.app.installedVersion == null) return false;
          if (nonInstalledOnly && a.app.installedVersion != null) return false;
          return a.app.installedVersion != a.app.latestVersion;
        })
        .map((a) => a.app)
        .toList();
  }

  String generateExportJSON(
    List<App> exportApps, {
    List<String>? appIds,
    int? overrideExportSettings,
  }) {
    if (appIds != null) {
      exportApps = exportApps.where((a) => appIds.contains(a.id)).toList();
    }
    Map<String, dynamic> data = {
      'apps': exportApps.map((e) => e.toJson()).toList()
    };
    return jsonEncode(data);
  }

  Future<void> openAppSettings(String appId) async {
  }
}

class MultiAppMultiError extends ObtainiumError {
  Map<String, dynamic> rawErrors = {};
  Map<String, List<String>> idsByErrorString = {};
  Map<String, String> appIdNames = {};

  MultiAppMultiError() : super(tr('placeholder'), unexpected: true);

  void add(String appId, dynamic error, {String? appName}) {
    if (error is SocketException) {
      error = error.message;
    }
    rawErrors[appId] = error;
    var string = error.toString();
    var tempIds = idsByErrorString.remove(string);
    tempIds ??= [];
    tempIds.add(appId);
    idsByErrorString.putIfAbsent(string, () => tempIds!);
    if (appName != null) {
      appIdNames[appId] = appName;
    }
  }

  String errorString(String appId, {bool includeIdsWithNames = false}) =>
      '${appIdNames.containsKey(appId) ? '${appIdNames[appId]}${includeIdsWithNames ? ' ($appId)' : ''}' : appId}: ${rawErrors[appId].toString()}';

  String errorsAppsString(
    String errString,
    List<String> appIds, {
    bool includeIdsWithNames = false,
  }) =>
      '$errString [${list2FriendlyString(appIds.map((id) => appIdNames.containsKey(id) == true ? '${appIdNames[id]}${includeIdsWithNames ? ' ($id)' : ''}' : id).toList())}]';

  @override
  String toString() => idsByErrorString.entries
      .map((e) => errorsAppsString(e.key, e.value))
      .join('\n\n');
}

class AppFilePicker extends StatefulWidget {
  final App app;
  final MapEntry<String, String>? initVal;
  final List<String> archs;
  final bool pickAnyAsset;

  const AppFilePicker({
    super.key,
    required this.app,
    this.initVal,
    required this.archs,
    required this.pickAnyAsset,
  });

  @override
  State<AppFilePicker> createState() => _AppFilePickerState();
}

class _AppFilePickerState extends State<AppFilePicker> {
  late MapEntry<String, String>? selectedUrl;

  @override
  void initState() {
    super.initState();
    selectedUrl = widget.initVal;
  }

  @override
  Widget build(BuildContext context) {
    var urls = widget.app.apkUrls;
    if (widget.pickAnyAsset) {
      urls = [...urls, ...widget.app.otherAssetUrls];
    }

    return AlertDialog(
      title: Text(tr('selectFile')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: urls.map((e) {
            return RadioListTile<MapEntry<String, String>>(
              title: Text(e.key),
              subtitle: Text(e.value, style: const TextStyle(fontSize: 10)),
              value: e,
              groupValue: selectedUrl,
              onChanged: (val) {
                setState(() {
                  selectedUrl = val;
                });
              },
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, selectedUrl),
          child: Text(tr('ok')),
        ),
      ],
    );
  }
}
