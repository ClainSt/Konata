import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ];

  /// Konata interface: settings
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// Konata interface: appearance
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// Konata interface: scraping
  ///
  /// In en, this message translates to:
  /// **'Metadata'**
  String get scraping;

  /// Konata interface: about
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// Konata interface: recordsSync
  ///
  /// In en, this message translates to:
  /// **'History & sync'**
  String get recordsSync;

  /// Konata interface: language
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// Konata interface: library
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get library;

  /// Konata interface: sources
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get sources;

  /// Konata interface: closeSettings
  ///
  /// In en, this message translates to:
  /// **'Close settings'**
  String get closeSettings;

  /// Konata interface: backSettings
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get backSettings;

  /// Konata interface: followSystem
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get followSystem;

  /// Konata interface: interfaceLanguage
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get interfaceLanguage;

  /// Konata interface: languageSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save language. Try again.'**
  String get languageSaveFailed;

  /// Konata interface: languageDescription
  ///
  /// In en, this message translates to:
  /// **'Metadata language stays unchanged. Some pages aren\'t translated yet.'**
  String get languageDescription;

  /// Konata interface: dayMode
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get dayMode;

  /// Konata interface: nightMode
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get nightMode;

  /// Konata interface: themeMode
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeMode;

  /// Konata interface: themeDescription
  ///
  /// In en, this message translates to:
  /// **'Light, dark or system'**
  String get themeDescription;

  /// Konata interface: themeSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save theme. Try again.'**
  String get themeSaveFailed;

  /// Konata interface: accent
  ///
  /// In en, this message translates to:
  /// **'Accent color'**
  String get accent;

  /// Konata interface: accentDescription
  ///
  /// In en, this message translates to:
  /// **'Choose a highlight color'**
  String get accentDescription;

  /// Konata interface: accentSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save color. Try again.'**
  String get accentSaveFailed;

  /// Konata interface: red
  ///
  /// In en, this message translates to:
  /// **'Red'**
  String get red;

  /// Konata interface: pink
  ///
  /// In en, this message translates to:
  /// **'Pink'**
  String get pink;

  /// Konata interface: lightBlue
  ///
  /// In en, this message translates to:
  /// **'Light blue'**
  String get lightBlue;

  /// Konata interface: switchLight
  ///
  /// In en, this message translates to:
  /// **'Light mode'**
  String get switchLight;

  /// Konata interface: switchDark
  ///
  /// In en, this message translates to:
  /// **'Dark mode'**
  String get switchDark;

  /// Konata interface: tmdbSettings
  ///
  /// In en, this message translates to:
  /// **'TMDB API'**
  String get tmdbSettings;

  /// Konata interface: credentialsConfigured
  ///
  /// In en, this message translates to:
  /// **'Credentials saved'**
  String get credentialsConfigured;

  /// Konata interface: credentialsMissing
  ///
  /// In en, this message translates to:
  /// **'Add a token or API key'**
  String get credentialsMissing;

  /// Konata interface: metadataServicesDescription
  ///
  /// In en, this message translates to:
  /// **'API servers, images and connection tests'**
  String get metadataServicesDescription;

  /// Konata interface: tmdbIdGuide
  ///
  /// In en, this message translates to:
  /// **'TMDB ID help'**
  String get tmdbIdGuide;

  /// Konata interface: history
  ///
  /// In en, this message translates to:
  /// **'Playback history'**
  String get history;

  /// Konata interface: historyDescription
  ///
  /// In en, this message translates to:
  /// **'Resume playback and manage watched status'**
  String get historyDescription;

  /// Konata interface: historyFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update history. Try again.'**
  String get historyFailed;

  /// Konata interface: clearHistoryQuestion
  ///
  /// In en, this message translates to:
  /// **'Clear history?'**
  String get clearHistoryQuestion;

  /// Konata interface: removeHistoryQuestion
  ///
  /// In en, this message translates to:
  /// **'Remove from history?'**
  String get removeHistoryQuestion;

  /// Konata interface: removeHistoryDescription
  ///
  /// In en, this message translates to:
  /// **'Clears resume points and playback entries. Files and metadata matches stay.'**
  String get removeHistoryDescription;

  /// Konata interface: cancel
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Konata interface: confirmDelete
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get confirmDelete;

  /// Konata interface: playFailed
  ///
  /// In en, this message translates to:
  /// **'Can\'t play this file. Check the source.'**
  String get playFailed;

  /// Konata interface: refreshHistory
  ///
  /// In en, this message translates to:
  /// **'Refresh history'**
  String get refreshHistory;

  /// Konata interface: clearHistory
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get clearHistory;

  /// Konata interface: readHistoryFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load history'**
  String get readHistoryFailed;

  /// Konata interface: retry
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Konata interface: noHistory
  ///
  /// In en, this message translates to:
  /// **'Nothing played yet'**
  String get noHistory;

  /// Konata interface: unknownWork
  ///
  /// In en, this message translates to:
  /// **'Unknown title'**
  String get unknownWork;

  /// Konata interface: watched
  ///
  /// In en, this message translates to:
  /// **'Watched'**
  String get watched;

  /// Konata interface: watching
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get watching;

  /// Konata interface: manageHistory
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get manageHistory;

  /// Konata interface: markUnwatched
  ///
  /// In en, this message translates to:
  /// **'Mark unwatched'**
  String get markUnwatched;

  /// Konata interface: markWatched
  ///
  /// In en, this message translates to:
  /// **'Mark watched'**
  String get markWatched;

  /// Konata interface: deleteRecord
  ///
  /// In en, this message translates to:
  /// **'Remove from history'**
  String get deleteRecord;

  /// Konata interface: enableLogs
  ///
  /// In en, this message translates to:
  /// **'Detailed debug logging'**
  String get enableLogs;

  /// Konata interface: logsDescription
  ///
  /// In en, this message translates to:
  /// **'Errors and essential playback events are always recorded. Enable before reproducing for more detail.'**
  String get logsDescription;

  /// Konata interface: logsSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save log settings'**
  String get logsSaveFailed;

  /// Konata interface: openLogs
  ///
  /// In en, this message translates to:
  /// **'Open log folder'**
  String get openLogs;

  /// Konata interface: exportLogsSystem
  ///
  /// In en, this message translates to:
  /// **'One TXT file with context around the latest incident'**
  String get exportLogsSystem;

  /// Konata interface: logsDefaultPath
  ///
  /// In en, this message translates to:
  /// **'App data / logs'**
  String get logsDefaultPath;

  /// Konata interface: versionLabel
  ///
  /// In en, this message translates to:
  /// **'Version 1.0.0'**
  String get versionLabel;

  /// Konata interface: noLogs
  ///
  /// In en, this message translates to:
  /// **'No recorded incident to export'**
  String get noLogs;

  /// Konata interface: exportLogs
  ///
  /// In en, this message translates to:
  /// **'Export latest incident'**
  String get exportLogs;

  /// Konata interface: logsAccessFailed
  ///
  /// In en, this message translates to:
  /// **'Can\'t open logs. Check your file manager.'**
  String get logsAccessFailed;

  /// Konata interface: chooseVersion
  ///
  /// In en, this message translates to:
  /// **'Choose version'**
  String get chooseVersion;

  /// Konata interface: closeVersion
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeVersion;

  /// Konata interface: filenameHints
  ///
  /// In en, this message translates to:
  /// **'Filename hints only. Check audio and subtitles during playback.'**
  String get filenameHints;

  /// Konata interface: unknownSource
  ///
  /// In en, this message translates to:
  /// **'Unknown source'**
  String get unknownSource;

  /// Konata interface: unnamedSource
  ///
  /// In en, this message translates to:
  /// **'Unnamed source'**
  String get unnamedSource;

  /// Konata interface: releaseTag
  ///
  /// In en, this message translates to:
  /// **'Release (unclassified)'**
  String get releaseTag;

  /// Konata interface: encoderTag
  ///
  /// In en, this message translates to:
  /// **'Encoder'**
  String get encoderTag;

  /// Konata interface: subtitleGroupTag
  ///
  /// In en, this message translates to:
  /// **'Subtitle group'**
  String get subtitleGroupTag;

  /// Konata interface: sourceLabel
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get sourceLabel;

  /// Konata interface: minimize
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get minimize;

  /// Konata interface: maximize
  ///
  /// In en, this message translates to:
  /// **'Maximize'**
  String get maximize;

  /// Konata interface: restoreWindow
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restoreWindow;

  /// Konata interface: closeWindow
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeWindow;

  /// Konata interface: apiGuideTitle
  ///
  /// In en, this message translates to:
  /// **'Get a TMDB key'**
  String get apiGuideTitle;

  /// Konata interface: apiGuideBody
  ///
  /// In en, this message translates to:
  /// **'1. Sign up or sign in at https://www.themoviedb.org/\n\n2. Go to Account settings → API. Use a desktop browser to apply.\n\n3. Enter your details and accept the terms.\n\n4. Return to Konata → TMDB API.\n\n5. Choose Access token for an API Read Access Token, or API Key for an API key. Don’t mix them up.\n\n6. Test the connection, then save. Keys stay in secure storage. Keep them private.\n\nAPI page: https://www.themoviedb.org/settings/api'**
  String get apiGuideBody;

  /// Konata interface: openApiPage
  ///
  /// In en, this message translates to:
  /// **'Open API page'**
  String get openApiPage;

  /// Konata interface: gotIt
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// Konata interface: browserCopyFailed
  ///
  /// In en, this message translates to:
  /// **'Can\'t open a browser. Copy the link below.'**
  String get browserCopyFailed;

  /// Konata interface: githubOpenFailed
  ///
  /// In en, this message translates to:
  /// **'Can\'t open a browser. Visit https://github.com/ClainSt/Konata'**
  String get githubOpenFailed;

  /// Konata interface: subtitleSimplified
  ///
  /// In en, this message translates to:
  /// **'Simplified Chinese'**
  String get subtitleSimplified;

  /// Konata interface: subtitleTraditional
  ///
  /// In en, this message translates to:
  /// **'Traditional Chinese'**
  String get subtitleTraditional;

  /// Konata interface: subtitleBilingual
  ///
  /// In en, this message translates to:
  /// **'Subs: Chinese / Japanese'**
  String get subtitleBilingual;

  /// Konata interface: subtitleAss
  ///
  /// In en, this message translates to:
  /// **'Subs: ASS'**
  String get subtitleAss;

  /// Konata interface: subtitlePgs
  ///
  /// In en, this message translates to:
  /// **'Subs: PGS'**
  String get subtitlePgs;

  /// Konata interface: authMethod
  ///
  /// In en, this message translates to:
  /// **'Sign in with'**
  String get authMethod;

  /// Konata interface: accessToken
  ///
  /// In en, this message translates to:
  /// **'Token'**
  String get accessToken;

  /// Konata interface: closeTmdb
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeTmdb;

  /// Konata interface: enterCredentials
  ///
  /// In en, this message translates to:
  /// **'Enter a token or API key first.'**
  String get enterCredentials;

  /// Konata interface: connectionOk
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connectionOk;

  /// Konata interface: credentialTestFailed
  ///
  /// In en, this message translates to:
  /// **'Connection failed. Check your key and network.'**
  String get credentialTestFailed;

  /// Konata interface: credentialSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save credentials. Try again.'**
  String get credentialSaveFailed;

  /// Konata interface: secureCredentials
  ///
  /// In en, this message translates to:
  /// **'Stored securely. Switch credentials anytime.'**
  String get secureCredentials;

  /// Konata interface: metadataProviders
  ///
  /// In en, this message translates to:
  /// **'TMDB and Bangumi metadata. No key needed for Bangumi search.'**
  String get metadataProviders;

  /// Konata interface: testConnection
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get testConnection;

  /// Konata interface: save
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Konata interface: closeIdGuide
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeIdGuide;

  /// Konata interface: idIntroTitle
  ///
  /// In en, this message translates to:
  /// **'TMDB IDs'**
  String get idIntroTitle;

  /// Konata interface: idIntroBody
  ///
  /// In en, this message translates to:
  /// **'Add a TMDB ID to a title folder for a more precise match. IDs take priority during scans. No setup needed.'**
  String get idIntroBody;

  /// Konata interface: idFormatsTitle
  ///
  /// In en, this message translates to:
  /// **'Formats'**
  String get idFormatsTitle;

  /// Konata interface: idFormats
  ///
  /// In en, this message translates to:
  /// **'Use {standard}\nAlso accepted: {alternate}, {brackets}\nKeep the brackets. Case does not matter. For films, use {movie}.'**
  String idFormats(
    String standard,
    String alternate,
    String brackets,
    String movie,
  );

  /// Konata interface: idExampleTitle
  ///
  /// In en, this message translates to:
  /// **'Example'**
  String get idExampleTitle;

  /// Konata interface: idExample
  ///
  /// In en, this message translates to:
  /// **'{path}\n\nTag each title folder, not the collection folder.'**
  String idExample(String path);

  /// Konata interface: idStepsTitle
  ///
  /// In en, this message translates to:
  /// **'Steps'**
  String get idStepsTitle;

  /// Konata interface: idSteps
  ///
  /// In en, this message translates to:
  /// **'1. Find the numeric ID in the TMDB page URL. Check the title and type.\n2. Add the tag to the folder name yourself. Konata does not rename your files.\n3. Rescan the folder. To fix an existing match, search and link it on the details page.'**
  String get idSteps;

  /// Konata interface: idNotesTitle
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get idNotesTitle;

  /// Konata interface: idNotes
  ///
  /// In en, this message translates to:
  /// **'• A working TMDB key and connection are still required.\n• Use S01E01 for episodes and S00E01 for specials. A title ID does not identify episodes.\n• Match the TMDB year, or omit it if unsure.\n• Locked metadata and custom covers stay unchanged.\n• Missing or incomplete entries may need a manual match.'**
  String get idNotes;

  /// Playback setting: autoWatched
  ///
  /// In en, this message translates to:
  /// **'Mark watched'**
  String get autoWatched;

  /// Playback setting: autoWatchedDescription
  ///
  /// In en, this message translates to:
  /// **'Mark a file watched after this much playback. Skips, pauses and replays add no extra credit. Manual status takes priority.'**
  String get autoWatchedDescription;

  /// Playback setting: watchSettingsSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save. Try again.'**
  String get watchSettingsSaveFailed;

  /// Playback setting: progressSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save progress. Retrying.'**
  String get progressSaveFailed;

  /// Konata interface: apiAddress
  ///
  /// In en, this message translates to:
  /// **'API URL'**
  String get apiAddress;

  /// Konata interface: imageAddress
  ///
  /// In en, this message translates to:
  /// **'Image URL'**
  String get imageAddress;

  /// Konata interface: testApi
  ///
  /// In en, this message translates to:
  /// **'Test API'**
  String get testApi;

  /// Konata interface: testImages
  ///
  /// In en, this message translates to:
  /// **'Test images'**
  String get testImages;

  /// Konata interface: connectionDetails
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get connectionDetails;

  /// Konata interface: resetDefaults
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get resetDefaults;

  /// Konata interface: officialServers
  ///
  /// In en, this message translates to:
  /// **'Official'**
  String get officialServers;

  /// Konata interface: closeMetadata
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeMetadata;

  /// Konata interface: serverNotice
  ///
  /// In en, this message translates to:
  /// **'Set API and image URLs separately. Bangumi uses a community mirror by default. HTTP is unencrypted.'**
  String get serverNotice;

  /// No description provided for @videoOutputRecovered.
  ///
  /// In en, this message translates to:
  /// **'Video output recovered.'**
  String get videoOutputRecovered;

  /// Konata interface: autoFallback
  ///
  /// In en, this message translates to:
  /// **'Auto fallback'**
  String get autoFallback;

  /// Konata interface: fallbackDescription
  ///
  /// In en, this message translates to:
  /// **'Use a backup server if requests fail. Tests use the entered URL.'**
  String get fallbackDescription;

  /// Konata interface: allowCustomCredentials
  ///
  /// In en, this message translates to:
  /// **'Send credentials to custom TMDB HTTPS servers'**
  String get allowCustomCredentials;

  /// Konata interface: notTested
  ///
  /// In en, this message translates to:
  /// **'Not tested'**
  String get notTested;

  /// Konata interface: testing
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get testing;

  /// Konata interface: serverConnected
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get serverConnected;

  /// Konata interface: connectionPartial
  ///
  /// In en, this message translates to:
  /// **'Some features failed'**
  String get connectionPartial;

  /// Konata interface: serverSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save. Check URLs and storage access.'**
  String get serverSaveFailed;

  /// Konata interface: diagnosticCredentials
  ///
  /// In en, this message translates to:
  /// **'Add a TMDB key first'**
  String get diagnosticCredentials;

  /// Konata interface: diagnosticAuth
  ///
  /// In en, this message translates to:
  /// **'Key rejected'**
  String get diagnosticAuth;

  /// Konata interface: diagnosticTimeout
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get diagnosticTimeout;

  /// Konata interface: diagnosticTls
  ///
  /// In en, this message translates to:
  /// **'TLS failed'**
  String get diagnosticTls;

  /// Konata interface: diagnosticNetwork
  ///
  /// In en, this message translates to:
  /// **'Network error'**
  String get diagnosticNetwork;

  /// Konata interface: diagnosticInvalid
  ///
  /// In en, this message translates to:
  /// **'Invalid URL or response'**
  String get diagnosticInvalid;

  /// Konata interface: diagnosticHttp
  ///
  /// In en, this message translates to:
  /// **'Server error'**
  String get diagnosticHttp;

  /// Konata interface: diagnosticFailed
  ///
  /// In en, this message translates to:
  /// **'Connection failed. Check URL and access.'**
  String get diagnosticFailed;

  /// Konata interface: audioTracks
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audioTracks;

  /// Konata interface: subtitles
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get subtitles;

  /// Konata interface: chooseSubtitles
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get chooseSubtitles;

  /// Konata interface: chooseAudio
  ///
  /// In en, this message translates to:
  /// **'Audio tracks'**
  String get chooseAudio;

  /// Konata interface: subtitlesOff
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get subtitlesOff;

  /// Konata interface: trackAuto
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get trackAuto;

  /// Konata interface: rewind10
  ///
  /// In en, this message translates to:
  /// **'Back 10s'**
  String get rewind10;

  /// Konata interface: forward10
  ///
  /// In en, this message translates to:
  /// **'Forward 10s'**
  String get forward10;

  /// Konata interface: play
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// Konata interface: pause
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// Konata interface: playbackFailed
  ///
  /// In en, this message translates to:
  /// **'Can\'t play. Check the file and source.'**
  String get playbackFailed;

  /// Playback track picker: audioOff
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get audioOff;

  /// Playback track picker: trackSwitchFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t switch tracks. Try again.'**
  String get trackSwitchFailed;

  /// Media sources: addMedia
  ///
  /// In en, this message translates to:
  /// **'Add media'**
  String get addMedia;

  /// Media sources: localMedia
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get localMedia;

  /// Media sources: networkMedia
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get networkMedia;

  /// Media sources: localFolder
  ///
  /// In en, this message translates to:
  /// **'Local folder'**
  String get localFolder;

  /// Media sources: addLocalFolder
  ///
  /// In en, this message translates to:
  /// **'Choose a media folder'**
  String get addLocalFolder;

  /// Media sources: addLocalTitle
  ///
  /// In en, this message translates to:
  /// **'Add folder'**
  String get addLocalTitle;

  /// Media sources: addWebdav
  ///
  /// In en, this message translates to:
  /// **'Add WebDAV'**
  String get addWebdav;

  /// Media sources: addSmb
  ///
  /// In en, this message translates to:
  /// **'Add SMB'**
  String get addSmb;

  /// Media sources: editSource
  ///
  /// In en, this message translates to:
  /// **'Edit source'**
  String get editSource;

  /// Media sources: sourceName
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get sourceName;

  /// Media sources: smbUrl
  ///
  /// In en, this message translates to:
  /// **'SMB URL'**
  String get smbUrl;

  /// Media sources: webdavUrl
  ///
  /// In en, this message translates to:
  /// **'WebDAV URL'**
  String get webdavUrl;

  /// Media sources: chooseFolder
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get chooseFolder;

  /// Media sources: chooseMediaFolder
  ///
  /// In en, this message translates to:
  /// **'Choose media folder'**
  String get chooseMediaFolder;

  /// Media sources: usernameOptional
  ///
  /// In en, this message translates to:
  /// **'Username (optional)'**
  String get usernameOptional;

  /// Media sources: newPassword
  ///
  /// In en, this message translates to:
  /// **'New password (optional)'**
  String get newPassword;

  /// Media sources: passwordWillClear
  ///
  /// In en, this message translates to:
  /// **'Saved password will be removed.'**
  String get passwordWillClear;

  /// Media sources: keepPassword
  ///
  /// In en, this message translates to:
  /// **'Leave blank to keep the password for the same user. Leave both blank for guest access.'**
  String get keepPassword;

  /// Media sources: undoClearPassword
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undoClearPassword;

  /// Media sources: clearSavedPassword
  ///
  /// In en, this message translates to:
  /// **'Clear saved password'**
  String get clearSavedPassword;

  /// Media sources: sourceFieldsRequired
  ///
  /// In en, this message translates to:
  /// **'Enter a name and location.'**
  String get sourceFieldsRequired;

  /// Media sources: invalidWebdav
  ///
  /// In en, this message translates to:
  /// **'Enter an HTTP or HTTPS URL.'**
  String get invalidWebdav;

  /// Media sources: invalidSmb
  ///
  /// In en, this message translates to:
  /// **'Enter smb://host/share.'**
  String get invalidSmb;

  /// Media sources: anonymousCredentials
  ///
  /// In en, this message translates to:
  /// **'Leave both fields blank for guest access.'**
  String get anonymousCredentials;

  /// Media sources: changeSourceTitle
  ///
  /// In en, this message translates to:
  /// **'Change location?'**
  String get changeSourceTitle;

  /// Media sources: changeSourceBody
  ///
  /// In en, this message translates to:
  /// **'Titles, manual matches, progress and source ID stay. Rescan if the new folder has different files.'**
  String get changeSourceBody;

  /// Media sources: confirmChange
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get confirmChange;

  /// No description provided for @sourceFolderMissing.
  ///
  /// In en, this message translates to:
  /// **'The folder or share could not be found.'**
  String get sourceFolderMissing;

  /// No description provided for @sourcePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Access denied. Check the folder permissions.'**
  String get sourcePermissionDenied;

  /// No description provided for @cancelScan.
  ///
  /// In en, this message translates to:
  /// **'Cancel scan'**
  String get cancelScan;

  /// No description provided for @scanCancelled.
  ///
  /// In en, this message translates to:
  /// **'Scan cancelled'**
  String get scanCancelled;

  /// No description provided for @scanStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping after the current operation…'**
  String get scanStopping;

  /// Media sources: sourceTestFailed
  ///
  /// In en, this message translates to:
  /// **'Connection failed. Check location, login and network.'**
  String get sourceTestFailed;

  /// Media sources: sourceSaveFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save source. Try again.'**
  String get sourceSaveFailed;

  /// Media sources: localAccessible
  ///
  /// In en, this message translates to:
  /// **'Folder found'**
  String get localAccessible;

  /// Media sources: localMissing
  ///
  /// In en, this message translates to:
  /// **'Folder not found'**
  String get localMissing;

  /// Media sources: sourceConnectHint
  ///
  /// In en, this message translates to:
  /// **'Connect, then choose folders to scan.'**
  String get sourceConnectHint;

  /// Media sources: connectionName
  ///
  /// In en, this message translates to:
  /// **'Name (optional)'**
  String get connectionName;

  /// Media sources: folderPickerHint
  ///
  /// In en, this message translates to:
  /// **'Select Add to choose a folder.'**
  String get folderPickerHint;

  /// Media sources: smbUrlHint
  ///
  /// In en, this message translates to:
  /// **'SMB URL (smb://host/share)'**
  String get smbUrlHint;

  /// Media sources: usernameCreate
  ///
  /// In en, this message translates to:
  /// **'Username (optional)'**
  String get usernameCreate;

  /// Media sources: smbUsername
  ///
  /// In en, this message translates to:
  /// **'Username (domain\\user supported)'**
  String get smbUsername;

  /// Media sources: passwordOptional
  ///
  /// In en, this message translates to:
  /// **'Password (optional)'**
  String get passwordOptional;

  /// Media sources: showPassword
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get showPassword;

  /// Media sources: hidePassword
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePassword;

  /// Media sources: guestHint
  ///
  /// In en, this message translates to:
  /// **'Leave login fields blank for guest access.'**
  String get guestHint;

  /// Media sources: add
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// Media sources: sourceAddFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t add source. Check the location.'**
  String get sourceAddFailed;

  /// Media sources: scanProgress
  ///
  /// In en, this message translates to:
  /// **'Scan progress'**
  String get scanProgress;

  /// Media sources: folderSearch
  ///
  /// In en, this message translates to:
  /// **'Search folder (name or TMDB ID)'**
  String get folderSearch;

  /// Media sources: clearSearch
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get clearSearch;

  /// Media sources: folderReadFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read folder. Check location and connection.'**
  String get folderReadFailed;

  /// Media sources: parentFolder
  ///
  /// In en, this message translates to:
  /// **'.. Up'**
  String get parentFolder;

  /// Media sources: fileLabel
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get fileLabel;

  /// Media sources: help
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get help;

  /// Media sources: chooseScanHelpTitle
  ///
  /// In en, this message translates to:
  /// **'Choose folders'**
  String get chooseScanHelpTitle;

  /// Media sources: chooseScanHelp
  ///
  /// In en, this message translates to:
  /// **'Check title folders or whole collections to scan. Uncertain matches are flagged for review. Select a folder name to browse inside.'**
  String get chooseScanHelp;

  /// Media sources: scanFolders
  ///
  /// In en, this message translates to:
  /// **'Scanning folders…'**
  String get scanFolders;

  /// Media sources: scanMetadata
  ///
  /// In en, this message translates to:
  /// **'Fetching metadata…'**
  String get scanMetadata;

  /// Media sources: scanComplete
  ///
  /// In en, this message translates to:
  /// **'Scan complete'**
  String get scanComplete;

  /// Media sources: scanFailed
  ///
  /// In en, this message translates to:
  /// **'Scan failed'**
  String get scanFailed;

  /// Media sources: noScan
  ///
  /// In en, this message translates to:
  /// **'No scans yet'**
  String get noScan;

  /// Media sources: noScanHint
  ///
  /// In en, this message translates to:
  /// **'Choose folders to start a scan.'**
  String get noScanHint;

  /// Media sources: scanScope
  ///
  /// In en, this message translates to:
  /// **'Selected folders (including subfolders)'**
  String get scanScope;

  /// Media sources: visitedFolders
  ///
  /// In en, this message translates to:
  /// **'Visited folders (direct video counts)'**
  String get visitedFolders;

  /// Media sources: noFoldersRead
  ///
  /// In en, this message translates to:
  /// **'No folders read yet'**
  String get noFoldersRead;

  /// Media sources: scanningShort
  ///
  /// In en, this message translates to:
  /// **'Scanning'**
  String get scanningShort;

  /// Media sources: sourceConnected
  ///
  /// In en, this message translates to:
  /// **'Connected: {count, plural, one {# item} other {# items}}'**
  String sourceConnected(int count);

  /// Media sources: browseSource
  ///
  /// In en, this message translates to:
  /// **'Browse · {name}'**
  String browseSource(String name);

  /// Media sources: itemCount
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {# item} other {# items}}'**
  String itemCount(int count);

  /// Media sources: videoCount
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {# video} other {# videos}}'**
  String videoCount(int count);

  /// Media sources: folderMatches
  ///
  /// In en, this message translates to:
  /// **'{found} of {total} items'**
  String folderMatches(int found, int total);

  /// Media sources: selectedScanFolders
  ///
  /// In en, this message translates to:
  /// **'Selected ({count})'**
  String selectedScanFolders(int count);

  /// Media sources: scanSelectedFolders
  ///
  /// In en, this message translates to:
  /// **'Scan selected ({count})'**
  String scanSelectedFolders(int count);

  /// Media sources: scannedFolderCount
  ///
  /// In en, this message translates to:
  /// **'Folders scanned: {count}'**
  String scannedFolderCount(int count);

  /// Media sources: indexedVideoCount
  ///
  /// In en, this message translates to:
  /// **'Videos indexed: {count}'**
  String indexedVideoCount(int count);

  /// Media sources: scanMetadataCount
  ///
  /// In en, this message translates to:
  /// **'Metadata: {done}/{total}'**
  String scanMetadataCount(int done, int total);

  /// Media sources: scanSummary
  ///
  /// In en, this message translates to:
  /// **'Matched: {matched} · Review: {review} · Failed: {failed}'**
  String scanSummary(int matched, int review, int failed);

  /// Media sources: currentScanFolder
  ///
  /// In en, this message translates to:
  /// **'Current folder: {path}'**
  String currentScanFolder(String path);

  /// Library/source controls: addSource
  ///
  /// In en, this message translates to:
  /// **'Add source'**
  String get addSource;

  /// Library/source controls: localDirectory
  ///
  /// In en, this message translates to:
  /// **'Local folder'**
  String get localDirectory;

  /// Library/source controls: browseScanFolders
  ///
  /// In en, this message translates to:
  /// **'Browse and choose scan folders'**
  String get browseScanFolders;

  /// Library/source controls: remove
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// Library/source controls: removeSourceTitle
  ///
  /// In en, this message translates to:
  /// **'Remove source?'**
  String get removeSourceTitle;

  /// Library/source controls: removeSourceBody
  ///
  /// In en, this message translates to:
  /// **'Remove the index only. Media files stay.'**
  String get removeSourceBody;

  /// Library/source controls: addSourceFirst
  ///
  /// In en, this message translates to:
  /// **'Add a source to get started'**
  String get addSourceFirst;

  /// Library/source controls: noMatchingTitles
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get noMatchingTitles;

  /// Library/source controls: searchTitles
  ///
  /// In en, this message translates to:
  /// **'Search works'**
  String get searchTitles;

  /// Library/source controls: closeSearch
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get closeSearch;

  /// Library/source controls: manageHidden
  ///
  /// In en, this message translates to:
  /// **'Hidden titles'**
  String get manageHidden;

  /// Library/source controls: sourceCount
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {# source} other {# sources}}'**
  String sourceCount(int count);

  /// Library/source controls: workCount
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {# title} other {# titles}}'**
  String workCount(int count);

  /// Title management: noHiddenTitles
  ///
  /// In en, this message translates to:
  /// **'No hidden titles'**
  String get noHiddenTitles;

  /// Title management: keepHidden
  ///
  /// In en, this message translates to:
  /// **'Keep hidden after rescans'**
  String get keepHidden;

  /// Title management: restoreOnScan
  ///
  /// In en, this message translates to:
  /// **'Rescans restore this title'**
  String get restoreOnScan;

  /// Title management: restoreTitle
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restoreTitle;

  /// Title management: titleNotFound
  ///
  /// In en, this message translates to:
  /// **'Title not found'**
  String get titleNotFound;

  /// Title management: scanBeforeRemove
  ///
  /// In en, this message translates to:
  /// **'Wait for the scan to finish.'**
  String get scanBeforeRemove;

  /// Title management: removeWorkTitle
  ///
  /// In en, this message translates to:
  /// **'Remove title?'**
  String get removeWorkTitle;

  /// Title management: removeWorkBody
  ///
  /// In en, this message translates to:
  /// **'Remove from the library only. Files, manual matches and progress stay.'**
  String get removeWorkBody;

  /// Title management: rescanRestoresHint
  ///
  /// In en, this message translates to:
  /// **'Otherwise, rescans restore it.'**
  String get rescanRestoresHint;

  /// Title management: removeFromLibrary
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeFromLibrary;

  /// Title management: removeWorkFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t remove title. Try again.'**
  String get removeWorkFailed;

  /// Title management: manualMatch
  ///
  /// In en, this message translates to:
  /// **'Match title'**
  String get manualMatch;

  /// Title management: nameOrId
  ///
  /// In en, this message translates to:
  /// **'Title or TMDB ID'**
  String get nameOrId;

  /// Title management: search
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// Title management: searchFailed
  ///
  /// In en, this message translates to:
  /// **'Search failed. Check credentials and network.'**
  String get searchFailed;

  /// Title management: bindFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save match. Try again.'**
  String get bindFailed;

  /// Title management: editMetadata
  ///
  /// In en, this message translates to:
  /// **'Edit details'**
  String get editMetadata;

  /// Title management: workTitle
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get workTitle;

  /// Title management: year
  ///
  /// In en, this message translates to:
  /// **'Year'**
  String get year;

  /// Title management: optional
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get optional;

  /// Title management: synopsis
  ///
  /// In en, this message translates to:
  /// **'Synopsis'**
  String get synopsis;

  /// Title management: notLinked
  ///
  /// In en, this message translates to:
  /// **'Not linked'**
  String get notLinked;

  /// Title management: bangumiIds
  ///
  /// In en, this message translates to:
  /// **'Bangumi IDs'**
  String get bangumiIds;

  /// Title management: bangumiIdsHint
  ///
  /// In en, this message translates to:
  /// **'Separate IDs with commas, e.g. 302189, 331887. Saving locks the match and keeps the title together.'**
  String get bangumiIdsHint;

  /// Title management: searchAndLink
  ///
  /// In en, this message translates to:
  /// **'Find match'**
  String get searchAndLink;

  /// Title management: invalidBangumiIds
  ///
  /// In en, this message translates to:
  /// **'Enter valid Bangumi IDs.'**
  String get invalidBangumiIds;

  /// Title management: invalidTitleYear
  ///
  /// In en, this message translates to:
  /// **'Enter a title and valid year.'**
  String get invalidTitleYear;

  /// Title management: characterOrder
  ///
  /// In en, this message translates to:
  /// **'Character order'**
  String get characterOrder;

  /// Title management: noCharactersYet
  ///
  /// In en, this message translates to:
  /// **'Load title details to see characters.'**
  String get noCharactersYet;

  /// Title management: recropCover
  ///
  /// In en, this message translates to:
  /// **'Crop again'**
  String get recropCover;

  /// Title management: editCover
  ///
  /// In en, this message translates to:
  /// **'Edit poster'**
  String get editCover;

  /// Title management: automaticCover
  ///
  /// In en, this message translates to:
  /// **'Use default'**
  String get automaticCover;

  /// Title management: importImage
  ///
  /// In en, this message translates to:
  /// **'Import image'**
  String get importImage;

  /// Title management: coverFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save poster. Check the image and storage.'**
  String get coverFailed;

  /// Title management: imageDecodeFailed
  ///
  /// In en, this message translates to:
  /// **'Can\'t open this image.'**
  String get imageDecodeFailed;

  /// Title management: cropFailed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t export crop. Try again.'**
  String get cropFailed;

  /// Title management: cropPoster
  ///
  /// In en, this message translates to:
  /// **'Crop poster · 2:3'**
  String get cropPoster;

  /// Title management: cropHint
  ///
  /// In en, this message translates to:
  /// **'Drag to move. Scroll or pinch to zoom. The frame is your poster.'**
  String get cropHint;

  /// Title management: lowResImage
  ///
  /// In en, this message translates to:
  /// **'Low-resolution image. No upscaling.'**
  String get lowResImage;

  /// Title management: reset
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// Title management: saving
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get saving;

  /// Title management: confirmSave
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get confirmSave;

  /// No description provided for @mainFeature.
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get mainFeature;

  /// No description provided for @extraFiles.
  ///
  /// In en, this message translates to:
  /// **'Extras'**
  String get extraFiles;

  /// No description provided for @allExtras.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get allExtras;

  /// No description provided for @otherExtra.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get otherExtra;

  /// No description provided for @unnamedVideo.
  ///
  /// In en, this message translates to:
  /// **'Untitled video'**
  String get unnamedVideo;

  /// No description provided for @unnamedWork.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get unnamedWork;

  /// No description provided for @cast.
  ///
  /// In en, this message translates to:
  /// **'Cast'**
  String get cast;

  /// No description provided for @crew.
  ///
  /// In en, this message translates to:
  /// **'Crew'**
  String get crew;

  /// No description provided for @characters.
  ///
  /// In en, this message translates to:
  /// **'Characters'**
  String get characters;

  /// No description provided for @collapseList.
  ///
  /// In en, this message translates to:
  /// **'Less'**
  String get collapseList;

  /// No description provided for @fullList.
  ///
  /// In en, this message translates to:
  /// **'Full list'**
  String get fullList;

  /// No description provided for @noExtras.
  ///
  /// In en, this message translates to:
  /// **'No extras'**
  String get noExtras;

  /// No description provided for @noLinkedEpisodes.
  ///
  /// In en, this message translates to:
  /// **'No linked episodes'**
  String get noLinkedEpisodes;

  /// No description provided for @backToLibrary.
  ///
  /// In en, this message translates to:
  /// **'Back to library'**
  String get backToLibrary;

  /// No description provided for @moreActions.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get moreActions;

  /// No description provided for @noMainFeature.
  ///
  /// In en, this message translates to:
  /// **'No episodes'**
  String get noMainFeature;

  /// No description provided for @startPlayback.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get startPlayback;

  /// No description provided for @noSynopsis.
  ///
  /// In en, this message translates to:
  /// **'No synopsis'**
  String get noSynopsis;

  /// No description provided for @collapseSynopsis.
  ///
  /// In en, this message translates to:
  /// **'Less'**
  String get collapseSynopsis;

  /// No description provided for @expandSynopsis.
  ///
  /// In en, this message translates to:
  /// **'Read more'**
  String get expandSynopsis;

  /// No description provided for @unwatchedStatus.
  ///
  /// In en, this message translates to:
  /// **'Unwatched'**
  String get unwatchedStatus;

  /// No description provided for @commercial.
  ///
  /// In en, this message translates to:
  /// **'Commercial'**
  String get commercial;

  /// No description provided for @promoVideo.
  ///
  /// In en, this message translates to:
  /// **'Promo'**
  String get promoVideo;

  /// No description provided for @cleanOpening.
  ///
  /// In en, this message translates to:
  /// **'Clean opening'**
  String get cleanOpening;

  /// No description provided for @cleanEnding.
  ///
  /// In en, this message translates to:
  /// **'Clean ending'**
  String get cleanEnding;

  /// No description provided for @discMenu.
  ///
  /// In en, this message translates to:
  /// **'Disc menu'**
  String get discMenu;

  /// No description provided for @specialEpisode.
  ///
  /// In en, this message translates to:
  /// **'Special'**
  String get specialEpisode;

  /// No description provided for @episodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Ep. {number}'**
  String episodeLabel(int number);

  /// No description provided for @detailEpisodeCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {# episode} other {# episodes}}'**
  String detailEpisodeCount(int count);

  /// No description provided for @detailVersionCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {# version} other {# versions}}'**
  String detailVersionCount(int count);

  /// No description provided for @resumeEpisode.
  ///
  /// In en, this message translates to:
  /// **'Resume {episode}'**
  String resumeEpisode(String episode);

  /// No description provided for @resumePlayback.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get resumePlayback;

  /// No description provided for @removeTitleAction.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeTitleAction;

  /// No description provided for @seekSeconds.
  ///
  /// In en, this message translates to:
  /// **'{count} s'**
  String seekSeconds(int count);

  /// No description provided for @tmdbOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Can\'t open a browser. Visit https://www.themoviedb.org'**
  String get tmdbOpenFailed;

  /// No description provided for @manualEdit.
  ///
  /// In en, this message translates to:
  /// **'Match episodes'**
  String get manualEdit;

  /// No description provided for @chooseSeason.
  ///
  /// In en, this message translates to:
  /// **'Choose season'**
  String get chooseSeason;

  /// No description provided for @chooseEpisode.
  ///
  /// In en, this message translates to:
  /// **'Choose episode'**
  String get chooseEpisode;

  /// No description provided for @keepMatch.
  ///
  /// In en, this message translates to:
  /// **'Keep match'**
  String get keepMatch;

  /// No description provided for @mappingHint.
  ///
  /// In en, this message translates to:
  /// **'Choose a title and season, then match each file. To change titles, match every file.'**
  String get mappingHint;

  /// No description provided for @mappingFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save. Check matches and try again.'**
  String get mappingFailed;

  /// No description provided for @loadingMatches.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get loadingMatches;

  /// No description provided for @playbackStats.
  ///
  /// In en, this message translates to:
  /// **'Stats'**
  String get playbackStats;

  /// No description provided for @chapters.
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get chapters;

  /// No description provided for @noChapters.
  ///
  /// In en, this message translates to:
  /// **'No chapters in this file'**
  String get noChapters;

  /// No description provided for @chapterReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t read chapters. Try again.'**
  String get chapterReadFailed;

  /// No description provided for @statsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get statsUnavailable;

  /// No description provided for @subtitleJapanese.
  ///
  /// In en, this message translates to:
  /// **'Japanese'**
  String get subtitleJapanese;

  /// No description provided for @subtitleChinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese'**
  String get subtitleChinese;

  /// No description provided for @losslessAudio.
  ///
  /// In en, this message translates to:
  /// **'Lossless'**
  String get losslessAudio;

  /// No description provided for @externalTrack.
  ///
  /// In en, this message translates to:
  /// **'External'**
  String get externalTrack;

  /// No description provided for @statVideo.
  ///
  /// In en, this message translates to:
  /// **'Video codec'**
  String get statVideo;

  /// No description provided for @statResolution.
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get statResolution;

  /// No description provided for @statFps.
  ///
  /// In en, this message translates to:
  /// **'Frame rate'**
  String get statFps;

  /// No description provided for @statOutputFps.
  ///
  /// In en, this message translates to:
  /// **'Output FPS'**
  String get statOutputFps;

  /// No description provided for @statHwdec.
  ///
  /// In en, this message translates to:
  /// **'Hardware decode'**
  String get statHwdec;

  /// No description provided for @statDropped.
  ///
  /// In en, this message translates to:
  /// **'Dropped frames'**
  String get statDropped;

  /// No description provided for @statDecoderDropped.
  ///
  /// In en, this message translates to:
  /// **'Decoder drops'**
  String get statDecoderDropped;

  /// No description provided for @statAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio codec'**
  String get statAudio;

  /// No description provided for @statSampleRate.
  ///
  /// In en, this message translates to:
  /// **'Sample rate (Hz)'**
  String get statSampleRate;

  /// No description provided for @statChannels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get statChannels;

  /// No description provided for @statBitrate.
  ///
  /// In en, this message translates to:
  /// **'Audio bitrate (bps)'**
  String get statBitrate;

  /// No description provided for @statCache.
  ///
  /// In en, this message translates to:
  /// **'Buffer (s)'**
  String get statCache;

  /// No description provided for @statAvsync.
  ///
  /// In en, this message translates to:
  /// **'A/V offset (s)'**
  String get statAvsync;

  /// No description provided for @timelinePreview.
  ///
  /// In en, this message translates to:
  /// **'Timeline preview'**
  String get timelinePreview;

  /// No description provided for @previewOn.
  ///
  /// In en, this message translates to:
  /// **'Timeline preview on'**
  String get previewOn;

  /// No description provided for @previewOff.
  ///
  /// In en, this message translates to:
  /// **'Timeline preview off'**
  String get previewOff;

  /// No description provided for @subtitleSimplifiedJapanese.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Simplified) + Japanese'**
  String get subtitleSimplifiedJapanese;

  /// No description provided for @subtitleTraditionalJapanese.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Traditional) + Japanese'**
  String get subtitleTraditionalJapanese;

  /// No description provided for @containedTrack.
  ///
  /// In en, this message translates to:
  /// **'Muxed'**
  String get containedTrack;

  /// No description provided for @importSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Import subtitles'**
  String get importSubtitle;

  /// No description provided for @trackNumber.
  ///
  /// In en, this message translates to:
  /// **'Track {number}'**
  String trackNumber(int number);

  /// No description provided for @exportLibraryBackup.
  ///
  /// In en, this message translates to:
  /// **'Export library backup'**
  String get exportLibraryBackup;

  /// No description provided for @exportLibraryBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Exports library data, viewing history and custom covers; excludes videos and saved credentials.'**
  String get exportLibraryBackupDescription;

  /// No description provided for @exportLibraryBackupDone.
  ///
  /// In en, this message translates to:
  /// **'Backup exported'**
  String get exportLibraryBackupDone;

  /// No description provided for @exportLibraryBackupFailed.
  ///
  /// In en, this message translates to:
  /// **'Backup export failed'**
  String get exportLibraryBackupFailed;

  /// No description provided for @exportLibraryBackupTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Backup is too large to save on this device'**
  String get exportLibraryBackupTooLarge;

  /// No description provided for @inspectLibraryBackup.
  ///
  /// In en, this message translates to:
  /// **'Inspect backup'**
  String get inspectLibraryBackup;

  /// No description provided for @inspectLibraryBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Verify a Konata backup without importing or changing data.'**
  String get inspectLibraryBackupDescription;

  /// No description provided for @inspectLibraryBackupFailed.
  ///
  /// In en, this message translates to:
  /// **'Backup validation failed'**
  String get inspectLibraryBackupFailed;

  /// No description provided for @playerSettings.
  ///
  /// In en, this message translates to:
  /// **'Player'**
  String get playerSettings;

  /// No description provided for @mpvConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Native MPV configuration'**
  String get mpvConfiguration;

  /// No description provided for @mpvEnable.
  ///
  /// In en, this message translates to:
  /// **'Use custom mpv.conf and input.conf'**
  String get mpvEnable;

  /// No description provided for @mpvEnableDetail.
  ///
  /// In en, this message translates to:
  /// **'Only use trusted files. Konata reads mpv.conf and input.conf before each playback.'**
  String get mpvEnableDetail;

  /// No description provided for @mpvNextPlayback.
  ///
  /// In en, this message translates to:
  /// **'Changes take effect when a new player opens.'**
  String get mpvNextPlayback;

  /// No description provided for @mpvEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get mpvEdit;

  /// No description provided for @mpvImport.
  ///
  /// In en, this message translates to:
  /// **'Import file'**
  String get mpvImport;

  /// No description provided for @mpvReset.
  ///
  /// In en, this message translates to:
  /// **'Restore empty default'**
  String get mpvReset;

  /// No description provided for @mpvFolderReadError.
  ///
  /// In en, this message translates to:
  /// **'Cannot read the configuration folder. Check the files or choose the folder again in player settings.'**
  String get mpvFolderReadError;

  /// No description provided for @mpvUseInternal.
  ///
  /// In en, this message translates to:
  /// **'Use in-app configuration'**
  String get mpvUseInternal;

  /// No description provided for @fullscreen.
  ///
  /// In en, this message translates to:
  /// **'Enter fullscreen'**
  String get fullscreen;

  /// No description provided for @exitFullscreen.
  ///
  /// In en, this message translates to:
  /// **'Exit fullscreen'**
  String get exitFullscreen;

  /// No description provided for @mpvOpenDirectory.
  ///
  /// In en, this message translates to:
  /// **'Choose configuration folder'**
  String get mpvOpenDirectory;

  /// No description provided for @mpvError.
  ///
  /// In en, this message translates to:
  /// **'MPV settings operation failed'**
  String get mpvError;

  /// No description provided for @mpvSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get mpvSave;

  /// No description provided for @backupPreviewCounts.
  ///
  /// In en, this message translates to:
  /// **'Works / Files / Sources / History / Covers'**
  String get backupPreviewCounts;

  /// No description provided for @confirmEpisodeIdentity.
  ///
  /// In en, this message translates to:
  /// **'Confirm episode identity'**
  String get confirmEpisodeIdentity;

  /// No description provided for @revokeEpisodeIdentity.
  ///
  /// In en, this message translates to:
  /// **'Remove identity confirmation'**
  String get revokeEpisodeIdentity;

  /// No description provided for @watchStateConflict.
  ///
  /// In en, this message translates to:
  /// **'Conflicting watched states'**
  String get watchStateConflict;

  /// No description provided for @confirmEpisodeDescription.
  ///
  /// In en, this message translates to:
  /// **'Check the title, season and episode. Only confirm if this file matches.'**
  String get confirmEpisodeDescription;

  /// No description provided for @historyEventsRetained.
  ///
  /// In en, this message translates to:
  /// **'Watch events are kept separately; deleting resume history does not mark an episode unwatched or delete events.'**
  String get historyEventsRetained;

  /// No description provided for @bangumiEpisodeMapping.
  ///
  /// In en, this message translates to:
  /// **'Bangumi episode'**
  String get bangumiEpisodeMapping;

  /// No description provided for @bangumiSubjectId.
  ///
  /// In en, this message translates to:
  /// **'Subject ID'**
  String get bangumiSubjectId;

  /// No description provided for @bangumiEpisodeId.
  ///
  /// In en, this message translates to:
  /// **'Episode ID'**
  String get bangumiEpisodeId;

  /// No description provided for @bangumiEpisodeType.
  ///
  /// In en, this message translates to:
  /// **'Episode type'**
  String get bangumiEpisodeType;

  /// No description provided for @bangumiMainStory.
  ///
  /// In en, this message translates to:
  /// **'Main story'**
  String get bangumiMainStory;

  /// No description provided for @verifyBangumiEpisode.
  ///
  /// In en, this message translates to:
  /// **'Check episode'**
  String get verifyBangumiEpisode;

  /// No description provided for @bangumiMappingDescription.
  ///
  /// In en, this message translates to:
  /// **'Check the subject, episode title, number and type. Numbering may differ from TMDB. This only saves a match.'**
  String get bangumiMappingDescription;

  /// No description provided for @bangumiMappingFailed.
  ///
  /// In en, this message translates to:
  /// **'Episode check failed. Check the IDs and type, then retry.'**
  String get bangumiMappingFailed;

  /// No description provided for @revokeBangumiMapping.
  ///
  /// In en, this message translates to:
  /// **'Remove episode match'**
  String get revokeBangumiMapping;

  /// No description provided for @statMpvVersion.
  ///
  /// In en, this message translates to:
  /// **'MPV version'**
  String get statMpvVersion;

  /// No description provided for @statHwdecSetting.
  ///
  /// In en, this message translates to:
  /// **'Decode setting'**
  String get statHwdecSetting;

  /// No description provided for @statPixelFormat.
  ///
  /// In en, this message translates to:
  /// **'Decoded pixel format'**
  String get statPixelFormat;

  /// No description provided for @statUnderlyingPixelFormat.
  ///
  /// In en, this message translates to:
  /// **'Underlying pixel format'**
  String get statUnderlyingPixelFormat;

  /// No description provided for @statColorMatrix.
  ///
  /// In en, this message translates to:
  /// **'Color matrix'**
  String get statColorMatrix;

  /// No description provided for @statColorPrimaries.
  ///
  /// In en, this message translates to:
  /// **'Color primaries'**
  String get statColorPrimaries;

  /// No description provided for @statTransferFunction.
  ///
  /// In en, this message translates to:
  /// **'Transfer function'**
  String get statTransferFunction;

  /// No description provided for @statColorRange.
  ///
  /// In en, this message translates to:
  /// **'Color range'**
  String get statColorRange;

  /// No description provided for @statVideoOutput.
  ///
  /// In en, this message translates to:
  /// **'Video output'**
  String get statVideoOutput;

  /// No description provided for @statFilteredWidth.
  ///
  /// In en, this message translates to:
  /// **'Filtered video width'**
  String get statFilteredWidth;

  /// No description provided for @statFilteredHeight.
  ///
  /// In en, this message translates to:
  /// **'Filtered video height'**
  String get statFilteredHeight;

  /// No description provided for @statCachePaused.
  ///
  /// In en, this message translates to:
  /// **'Paused for cache'**
  String get statCachePaused;

  /// No description provided for @statSourceDepth.
  ///
  /// In en, this message translates to:
  /// **'Decoded component depth (known formats)'**
  String get statSourceDepth;

  /// No description provided for @statTextureSize.
  ///
  /// In en, this message translates to:
  /// **'Flutter texture size'**
  String get statTextureSize;

  /// No description provided for @statFilteredDepth.
  ///
  /// In en, this message translates to:
  /// **'Component depth after filters'**
  String get statFilteredDepth;

  /// No description provided for @statTargetDepth.
  ///
  /// In en, this message translates to:
  /// **'MPV target depth (reported)'**
  String get statTargetDepth;

  /// No description provided for @statTargetPrimaries.
  ///
  /// In en, this message translates to:
  /// **'MPV target primaries'**
  String get statTargetPrimaries;

  /// No description provided for @statTargetTransfer.
  ///
  /// In en, this message translates to:
  /// **'MPV target transfer function'**
  String get statTargetTransfer;

  /// No description provided for @statPresentationDepth.
  ///
  /// In en, this message translates to:
  /// **'Final presentation depth (unmeasured)'**
  String get statPresentationDepth;

  /// No description provided for @statDecodedAudioFormat.
  ///
  /// In en, this message translates to:
  /// **'Decoded audio sample format'**
  String get statDecodedAudioFormat;

  /// No description provided for @statOutputAudioFormat.
  ///
  /// In en, this message translates to:
  /// **'Audio API sample format'**
  String get statOutputAudioFormat;

  /// No description provided for @statOutputSampleRate.
  ///
  /// In en, this message translates to:
  /// **'Audio API sample rate'**
  String get statOutputSampleRate;

  /// No description provided for @statOutputChannels.
  ///
  /// In en, this message translates to:
  /// **'Audio API channel layout'**
  String get statOutputChannels;

  /// No description provided for @statAudioOutput.
  ///
  /// In en, this message translates to:
  /// **'Audio output'**
  String get statAudioOutput;

  /// No description provided for @restoreLibraryBackup.
  ///
  /// In en, this message translates to:
  /// **'Restore from backup'**
  String get restoreLibraryBackup;

  /// No description provided for @restoreLibraryBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Preview and restore your library, history, custom covers and basic settings from a ZIP backup.'**
  String get restoreLibraryBackupDescription;

  /// No description provided for @restoreLibraryBackupWarning.
  ///
  /// In en, this message translates to:
  /// **'This replaces your current library and playback history; it does not merge them. A backup of current data is saved first. Failed changes are rolled back.\n\nMedia files are not included. Re-enter source passwords. On another device, select and authorize local folders again in Edit source. Restore does not scan or connect to sources.'**
  String get restoreLibraryBackupWarning;

  /// No description provided for @restoringLibraryBackup.
  ///
  /// In en, this message translates to:
  /// **'Restoring, please wait…'**
  String get restoringLibraryBackup;

  /// No description provided for @restoreLibraryBackupDone.
  ///
  /// In en, this message translates to:
  /// **'Restore complete. Edit sources to reconnect folders or re-enter passwords if needed.'**
  String get restoreLibraryBackupDone;

  /// No description provided for @restoreLibraryBackupFailed.
  ///
  /// In en, this message translates to:
  /// **'Restore did not complete. Check the backup and available storage, then try again.'**
  String get restoreLibraryBackupFailed;

  /// No description provided for @restoreLibraryBackupBusy.
  ///
  /// In en, this message translates to:
  /// **'Wait for scanning to finish before restoring a backup.'**
  String get restoreLibraryBackupBusy;

  /// No description provided for @previousLibraryBackup.
  ///
  /// In en, this message translates to:
  /// **'Backups before restore'**
  String get previousLibraryBackup;

  /// No description provided for @previousLibraryBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Preview and restore either of the last two automatic backups.'**
  String get previousLibraryBackupDescription;

  /// No description provided for @noPreviousLibraryBackup.
  ///
  /// In en, this message translates to:
  /// **'No automatic backup has been created yet.'**
  String get noPreviousLibraryBackup;

  /// No description provided for @restoreCurrentLibrary.
  ///
  /// In en, this message translates to:
  /// **'Current library (works / files / sources)'**
  String get restoreCurrentLibrary;

  /// No description provided for @extensions.
  ///
  /// In en, this message translates to:
  /// **'Extensions'**
  String get extensions;

  /// No description provided for @extensionsDescription.
  ///
  /// In en, this message translates to:
  /// **'Enable optional features here. Their settings appear under Scraping services when enabled. Turning a feature off stops its requests and releases its temporary resources.'**
  String get extensionsDescription;

  /// No description provided for @characterDetails.
  ///
  /// In en, this message translates to:
  /// **'Characters and voice actors'**
  String get characterDetails;

  /// No description provided for @characterDetailsDescription.
  ///
  /// In en, this message translates to:
  /// **'Show Bangumi character and voice actor details on title pages.'**
  String get characterDetailsDescription;

  /// No description provided for @voiceActorPhotos.
  ///
  /// In en, this message translates to:
  /// **'Use voice actor photos'**
  String get voiceActorPhotos;

  /// No description provided for @creditsDetails.
  ///
  /// In en, this message translates to:
  /// **'Cast and crew'**
  String get creditsDetails;

  /// No description provided for @creditsDetailsDescription.
  ///
  /// In en, this message translates to:
  /// **'Show TMDB cast and crew on live-action title pages.'**
  String get creditsDetailsDescription;

  /// No description provided for @creditsServiceSettings.
  ///
  /// In en, this message translates to:
  /// **'Uses the shared TMDB credentials. Open API settings.'**
  String get creditsServiceSettings;

  /// No description provided for @optionalFeatureFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load or save this feature. Please retry.'**
  String get optionalFeatureFailed;

  /// No description provided for @optionalNoResults.
  ///
  /// In en, this message translates to:
  /// **'No details available.'**
  String get optionalNoResults;

  /// No description provided for @animationCategory.
  ///
  /// In en, this message translates to:
  /// **'Animation'**
  String get animationCategory;

  /// No description provided for @liveActionCategory.
  ///
  /// In en, this message translates to:
  /// **'Live action'**
  String get liveActionCategory;

  /// No description provided for @featureOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get featureOff;

  /// No description provided for @voiceActors.
  ///
  /// In en, this message translates to:
  /// **'Voice actors'**
  String get voiceActors;

  /// No description provided for @sage.
  ///
  /// In en, this message translates to:
  /// **'Sage'**
  String get sage;

  /// No description provided for @allWorks.
  ///
  /// In en, this message translates to:
  /// **'All titles'**
  String get allWorks;

  /// No description provided for @compactWorkCount.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String compactWorkCount(int count);

  /// No description provided for @bangumiPeopleData.
  ///
  /// In en, this message translates to:
  /// **'Bangumi characters / voice actors'**
  String get bangumiPeopleData;

  /// No description provided for @tmdbPeopleData.
  ///
  /// In en, this message translates to:
  /// **'TMDB people'**
  String get tmdbPeopleData;

  /// No description provided for @peopleBar.
  ///
  /// In en, this message translates to:
  /// **'Character row'**
  String get peopleBar;

  /// No description provided for @peopleFallbackTmdb.
  ///
  /// In en, this message translates to:
  /// **'When Bangumi is off, use TMDB people.'**
  String get peopleFallbackTmdb;

  /// No description provided for @peopleFallbackHidden.
  ///
  /// In en, this message translates to:
  /// **'When Bangumi is off, hide the character row.'**
  String get peopleFallbackHidden;

  /// No description provided for @historySelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get historySelectAll;

  /// No description provided for @historyDeselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get historyDeselectAll;

  /// No description provided for @historySelectionCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String historySelectionCount(int count);

  /// No description provided for @deleteHistorySelectionQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} selected records?'**
  String deleteHistorySelectionQuestion(int count);

  /// No description provided for @imageCache.
  ///
  /// In en, this message translates to:
  /// **'Image cache'**
  String get imageCache;

  /// No description provided for @measuringCache.
  ///
  /// In en, this message translates to:
  /// **'Measuring…'**
  String get measuringCache;

  /// No description provided for @cacheSizeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unable to measure'**
  String get cacheSizeUnavailable;

  /// No description provided for @openCacheDirectory.
  ///
  /// In en, this message translates to:
  /// **'Open cache folder'**
  String get openCacheDirectory;

  /// No description provided for @cacheDirectoryUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Cannot open the cache folder.'**
  String get cacheDirectoryUnavailable;

  /// No description provided for @detailBackdrop.
  ///
  /// In en, this message translates to:
  /// **'Detail page background'**
  String get detailBackdrop;

  /// No description provided for @cacheSettingFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save this setting.'**
  String get cacheSettingFailed;

  /// No description provided for @nameOrBangumiId.
  ///
  /// In en, this message translates to:
  /// **'Name or Bangumi ID'**
  String get nameOrBangumiId;

  /// No description provided for @unclassified.
  ///
  /// In en, this message translates to:
  /// **'Unclassified'**
  String get unclassified;

  /// No description provided for @assignToWork.
  ///
  /// In en, this message translates to:
  /// **'Assign to title'**
  String get assignToWork;

  /// No description provided for @workName.
  ///
  /// In en, this message translates to:
  /// **'Title name'**
  String get workName;

  /// No description provided for @createClassification.
  ///
  /// In en, this message translates to:
  /// **'Create title with this name'**
  String get createClassification;

  /// No description provided for @classificationHint.
  ///
  /// In en, this message translates to:
  /// **'Only library assignments change; original files stay in place. Select files from one source, then assign them to an existing or new title.'**
  String get classificationHint;

  /// No description provided for @selectSourceFiles.
  ///
  /// In en, this message translates to:
  /// **'Select all from this source'**
  String get selectSourceFiles;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+script codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.scriptCode) {
          case 'Hans':
            return AppLocalizationsZhHans();
          case 'Hant':
            return AppLocalizationsZhHant();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
