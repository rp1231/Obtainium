import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/pages/home.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/native_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';

List<MapEntry<Locale, String>> supportedLocales = const [
  MapEntry(Locale('en'), 'English'),
  MapEntry(Locale('zh'), '简体中文'),
  MapEntry(Locale('zh', 'Hant_TW'), '臺灣話'),
  MapEntry(Locale('it'), 'Italiano'),
  MapEntry(Locale('ja'), '日本語'),
  MapEntry(Locale('hu'), 'Magyar'),
  MapEntry(Locale('de'), 'Deutsch'),
  MapEntry(Locale('fa'), 'فارسی'),
  MapEntry(Locale('fr'), 'Français'),
  MapEntry(Locale('es'), 'Español'),
  MapEntry(Locale('pl'), 'Polski'),
  MapEntry(Locale('ru'), 'Русский'),
  MapEntry(Locale('bs'), 'Bosanski'),
  MapEntry(Locale('pt'), 'Português'),
  MapEntry(Locale('pt', 'BR'), 'Brasileiro'),
  MapEntry(Locale('cs'), 'Česky'),
  MapEntry(Locale('sv'), 'Svenska'),
  MapEntry(Locale('nl'), 'Nederlands'),
  MapEntry(Locale('vi'), 'Tiếng Việt'),
  MapEntry(Locale('tr'), 'Türkçe'),
  MapEntry(Locale('uk'), 'Українська'),
  MapEntry(Locale('da'), 'Dansk'),
  MapEntry(Locale('en', 'EO'), 'Esperanto'),
  MapEntry(Locale('in'), 'Bahasa Indonesia'),
  MapEntry(Locale('ko'), '한국어'),
  MapEntry(Locale('ca'), 'Català'),
  MapEntry(Locale('ar'), 'العربية'),
  MapEntry(Locale('ml'), 'മലയാളം'),
  MapEntry(Locale('gl'), 'Galego'),
];
const fallbackLocale = Locale('en');
const localeDir = 'assets/translations';

final globalNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await EasyLocalization.ensureInitialized();
    
    final np = NotificationsProvider();
    await np.initialize();
    
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (context) => AppsProvider()),
          ChangeNotifierProvider(create: (context) => SettingsProvider()),
          Provider(create: (context) => np),
          Provider(create: (context) => LogsProvider()),
        ],
        child: EasyLocalization(
          supportedLocales: supportedLocales.map((e) => e.key).toList(),
          path: localeDir,
          fallbackLocale: fallbackLocale,
          useOnlyLangCode: false,
          child: const Obtainium(),
        ),
      ),
    );
  } catch (e, s) {
    try {
      File('crash_log.txt').writeAsStringSync('Error: $e\nStackTrace: $s');
    } catch (_) {}
    rethrow;
  }
}

class Obtainium extends StatefulWidget {
  const Obtainium({super.key});

  @override
  State<Obtainium> createState() => _ObtainiumState();
}

class _ObtainiumState extends State<Obtainium> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    SettingsProvider settingsProvider = context.watch<SettingsProvider>();
    if (settingsProvider.prefs == null) {
      settingsProvider.initializeSettings();
    }

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme lightColorScheme;
        ColorScheme darkColorScheme;
        if (lightDynamic != null &&
            darkDynamic != null &&
            settingsProvider.useMaterialYou) {
          lightColorScheme = lightDynamic.harmonized();
          darkColorScheme = darkDynamic.harmonized();
        } else {
          lightColorScheme = ColorScheme.fromSeed(
            seedColor: settingsProvider.themeColor,
          );
          darkColorScheme = ColorScheme.fromSeed(
            seedColor: settingsProvider.themeColor,
            brightness: Brightness.dark,
          );
        }

        if (settingsProvider.useBlackTheme) {
          darkColorScheme = darkColorScheme
              .copyWith(surface: Colors.black)
              .harmonized();
        }

        return MaterialApp(
          title: 'Obtainium',
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          navigatorKey: globalNavigatorKey,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: settingsProvider.theme == ThemeSettings.dark
                ? darkColorScheme
                : lightColorScheme,
            fontFamily: 'Montserrat',
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: settingsProvider.theme == ThemeSettings.light
                ? lightColorScheme
                : darkColorScheme,
            fontFamily: 'Montserrat',
          ),
          home: Shortcuts(
            shortcuts: <LogicalKeySet, Intent>{
              LogicalKeySet(LogicalKeyboardKey.select):
                  const ActivateIntent(),
            },
            child: const HomePage(),
          ),
        );
      },
    );
  }
}
