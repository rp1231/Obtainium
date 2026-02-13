// Exposes functions that can be used to send notifications to the user
// Contains a set of pre-defined ObtainiumNotification objects that should be used throughout the app

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
// import 'package:win_toast/win_toast.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

enum Importance {
  none,
  min,
  low,
  defaultImportance,
  high,
  max,
  unspecified
}

class ObtainiumNotification {
  late int id;
  late String title;
  late String message;
  late String channelCode;
  late String channelName;
  late String channelDescription;
  Importance importance;
  int? progPercent;
  bool onlyAlertOnce;
  String? payload;

  ObtainiumNotification(
    this.id,
    this.title,
    this.message,
    this.channelCode,
    this.channelName,
    this.channelDescription,
    this.importance, {
    this.onlyAlertOnce = false,
    this.progPercent,
    this.payload,
  });
}

class UpdateNotification extends ObtainiumNotification {
  UpdateNotification(List<App> updates, {int? id})
    : super(
        id ?? 2,
        tr('updatesAvailable'),
        '',
        'UPDATES_AVAILABLE',
        tr('updatesAvailableNotifChannel'),
        tr('updatesAvailableNotifDescription'),
        Importance.max,
      ) {
    message = updates.isEmpty
        ? tr('noNewUpdates')
        : updates.length == 1
        ? tr('xHasAnUpdate', args: [updates[0].finalName])
        : plural(
            'xAndNMoreUpdatesAvailable',
            updates.length - 1,
            args: [updates[0].finalName, (updates.length - 1).toString()],
          );
  }
}

class SilentUpdateNotification extends ObtainiumNotification {
  SilentUpdateNotification(List<App> updates, bool succeeded, {int? id})
    : super(
        id ?? 3,
        succeeded ? tr('appsUpdated') : tr('appsNotUpdated'),
        '',
        'APPS_UPDATED',
        tr('appsUpdatedNotifChannel'),
        tr('appsUpdatedNotifDescription'),
        Importance.defaultImportance,
      ) {
    message = updates.length == 1
        ? tr(
            succeeded ? 'xWasUpdatedToY' : 'xWasNotUpdatedToY',
            args: [updates[0].finalName, updates[0].latestVersion],
          )
        : plural(
            succeeded ? 'xAndNMoreUpdatesInstalled' : "xAndNMoreUpdatesFailed",
            updates.length - 1,
            args: [updates[0].finalName, (updates.length - 1).toString()],
          );
  }
}

class SilentUpdateAttemptNotification extends ObtainiumNotification {
  SilentUpdateAttemptNotification(List<App> updates, {int? id})
    : super(
        id ?? 3,
        tr('appsPossiblyUpdated'),
        '',
        'APPS_POSSIBLY_UPDATED',
        tr('appsPossiblyUpdatedNotifChannel'),
        tr('appsPossiblyUpdatedNotifDescription'),
        Importance.defaultImportance,
      ) {
    message = updates.length == 1
        ? tr(
            'xWasPossiblyUpdatedToY',
            args: [updates[0].finalName, updates[0].latestVersion],
          )
        : plural(
            'xAndNMoreUpdatesPossiblyInstalled',
            updates.length - 1,
            args: [updates[0].finalName, (updates.length - 1).toString()],
          );
  }
}

class ErrorCheckingUpdatesNotification extends ObtainiumNotification {
  ErrorCheckingUpdatesNotification(String error, {int? id})
    : super(
        id ?? 5,
        tr('errorCheckingUpdates'),
        error,
        'BG_UPDATE_CHECK_ERROR',
        tr('errorCheckingUpdatesNotifChannel'),
        tr('errorCheckingUpdatesNotifDescription'),
        Importance.high,
        payload: "${tr('errorCheckingUpdates')}\n$error",
      );
}

class AppsRemovedNotification extends ObtainiumNotification {
  AppsRemovedNotification(List<List<String>> namedReasons)
    : super(
        6,
        tr('appsRemoved'),
        '',
        'APPS_REMOVED',
        tr('appsRemovedNotifChannel'),
        tr('appsRemovedNotifDescription'),
        Importance.max,
      ) {
    message = '';
    for (var r in namedReasons) {
      message += '${tr('xWasRemovedDueToErrorY', args: [r[0], r[1]])} \n';
    }
    message = message.trim();
  }
}

class DownloadNotification extends ObtainiumNotification {
  DownloadNotification(String appName, int progPercent)
    : super(
        appName.hashCode,
        tr('downloadingX', args: [appName]),
        '',
        'APP_DOWNLOADING',
        tr('downloadingXNotifChannel', args: [tr('app')]),
        tr('downloadNotifDescription'),
        Importance.low,
        onlyAlertOnce: true,
        progPercent: progPercent,
      );
}

class DownloadedNotification extends ObtainiumNotification {
  DownloadedNotification(String fileName, String downloadUrl)
    : super(
        downloadUrl.hashCode,
        tr('downloadedX', args: [fileName]),
        '',
        'FILE_DOWNLOADED',
        tr('downloadedXNotifChannel', args: [tr('app')]),
        tr('downloadedX', args: [tr('app')]),
        Importance.defaultImportance,
      );
}

ObtainiumNotification get completeInstallationNotification => ObtainiumNotification(
  1,
  tr('completeAppInstallation'),
  tr('obtainiumMustBeOpenToInstallApps'),
  'COMPLETE_INSTALL',
  tr('completeAppInstallationNotifChannel'),
  tr('completeAppInstallationNotifDescription'),
  Importance.max,
);

class CheckingUpdatesNotification extends ObtainiumNotification {
  CheckingUpdatesNotification(String appName)
    : super(
        4,
        tr('checkingForUpdates'),
        appName,
        'BG_UPDATE_CHECK',
        tr('checkingForUpdatesNotifChannel'),
        tr('checkingForUpdatesNotifDescription'),
        Importance.min,
      );
}

class NotificationsProvider {
  bool isInitialized = false;

  Future<void> initialize() async {
    if (isInitialized) return;
    /*
    isInitialized = await WinToast.instance().initialize(
      aumId: 'Obtainium',
      displayName: 'Obtainium',
      iconPath: '',
      clsid: '{5DE36BB4-6CD1-46C1-BE3A-27AF0A973FD9}',
    );

    WinToast.instance().setActivatedCallback((event) {
      _showNotificationPayload(event.argument);
    });
    */
    isInitialized = true;
  }

  Future<void> checkLaunchByNotif() async {
    // Not directly supported by win_toast, but usually handled by callbacks if initialized early.
  }

  void _showNotificationPayload(String? payload, {bool doublePop = false}) {
    if (payload?.isNotEmpty == true) {
      var parts = payload!.split('\n');
      var title = parts.first;
      var content = parts.length > 1 ? parts.sublist(1).join('\n') : '';
      globalNavigatorKey.currentState?.push(
        PageRouteBuilder(
          pageBuilder: (context, _, __) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(null);
                  if (doublePop) {
                    Navigator.of(context).pop(null);
                  }
                },
                child: Text(tr('ok')),
              ),
            ],
          ),
        ),
      );
    }
  }

  Future<void> cancel(int id) async {
    // await WinToast.instance().dismiss(tag: id.toString(), group: 'Obtainium');
  }

  Future<void> notifyRaw(
    int id,
    String title,
    String message,
    String channelCode,
    String channelName,
    String channelDescription,
    Importance importance, {
    bool cancelExisting = false,
    int? progPercent,
    bool onlyAlertOnce = false,
    String? payload,
  }) async {
    if (!isInitialized) {
      await initialize();
    }
    /*
    String progressXml = '';
    if (progPercent != null) {
      double value = progPercent >= 0 ? progPercent / 100.0 : 0.0;
      String valueString = progPercent >= 0 ? '$progPercent%' : '';
      progressXml = '<progress title="$title" status="$message" value="$value" valueStringOverride="$valueString" />';
    }

    String xml = """
<toast launch="${payload ?? ''}">
  <visual>
    <binding template="ToastGeneric">
      <text>$title</text>
      <text>$message</text>
      $progressXml
    </binding>
  </visual>
</toast>
""";

    await WinToast.instance().showCustomToast(
      xml: xml,
      tag: id.toString(),
      group: 'Obtainium',
    );
    */
  }

  Future<void> notify(
    ObtainiumNotification notif, {
    bool cancelExisting = false,
  }) => notifyRaw(
    notif.id,
    notif.title,
    notif.message,
    notif.channelCode,
    notif.channelName,
    notif.channelDescription,
    notif.importance,
    cancelExisting: cancelExisting,
    onlyAlertOnce: notif.onlyAlertOnce,
    progPercent: notif.progPercent,
    payload: notif.payload,
  );
}
