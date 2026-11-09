// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settings => 'Settings';

  @override
  String get appearance => 'Appearance';

  @override
  String get scraping => 'Metadata';

  @override
  String get about => 'About';

  @override
  String get recordsSync => 'History & sync';

  @override
  String get language => 'Language';

  @override
  String get library => 'Library';

  @override
  String get sources => 'Sources';

  @override
  String get closeSettings => 'Close settings';

  @override
  String get backSettings => 'Back';

  @override
  String get followSystem => 'System';

  @override
  String get interfaceLanguage => 'App language';

  @override
  String get languageSaveFailed => 'Couldn\'t save language. Try again.';

  @override
  String get languageDescription =>
      'Metadata language stays unchanged. Some pages aren\'t translated yet.';

  @override
  String get dayMode => 'Light';

  @override
  String get nightMode => 'Dark';

  @override
  String get themeMode => 'Theme';

  @override
  String get themeDescription => 'Light, dark or system';

  @override
  String get themeSaveFailed => 'Couldn\'t save theme. Try again.';

  @override
  String get accent => 'Accent color';

  @override
  String get accentDescription => 'Choose a highlight color';

  @override
  String get accentSaveFailed => 'Couldn\'t save color. Try again.';

  @override
  String get red => 'Red';

  @override
  String get pink => 'Pink';

  @override
  String get lightBlue => 'Light blue';

  @override
  String get switchLight => 'Light mode';

  @override
  String get switchDark => 'Dark mode';

  @override
  String get tmdbSettings => 'TMDB API';

  @override
  String get credentialsConfigured => 'Credentials saved';

  @override
  String get credentialsMissing => 'Add a token or API key';

  @override
  String get metadataServicesDescription =>
      'API servers, images and connection tests';

  @override
  String get tmdbIdGuide => 'TMDB ID help';

  @override
  String get history => 'Playback history';

  @override
  String get historyDescription => 'Resume playback and manage watched status';

  @override
  String get historyFailed => 'Couldn\'t update history. Try again.';

  @override
  String get clearHistoryQuestion => 'Clear history?';

  @override
  String get removeHistoryQuestion => 'Remove from history?';

  @override
  String get removeHistoryDescription =>
      'Clears resume points and playback entries. Files and metadata matches stay.';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirmDelete => 'Delete';

  @override
  String get playFailed => 'Can\'t play this file. Check the source.';

  @override
  String get refreshHistory => 'Refresh history';

  @override
  String get clearHistory => 'Clear history';

  @override
  String get readHistoryFailed => 'Couldn\'t load history';

  @override
  String get retry => 'Retry';

  @override
  String get noHistory => 'Nothing played yet';

  @override
  String get unknownWork => 'Unknown title';

  @override
  String get watched => 'Watched';

  @override
  String get watching => 'In progress';

  @override
  String get manageHistory => 'More';

  @override
  String get markUnwatched => 'Mark unwatched';

  @override
  String get markWatched => 'Mark watched';

  @override
  String get deleteRecord => 'Remove from history';

  @override
  String get enableLogs => 'Detailed debug logging';

  @override
  String get logsDescription =>
      'Errors and essential playback events are always recorded. Enable before reproducing for more detail.';

  @override
  String get logsSaveFailed => 'Couldn\'t save log settings';

  @override
  String get openLogs => 'Open log folder';

  @override
  String get exportLogsSystem =>
      'One TXT file with context around the latest incident';

  @override
  String get logsDefaultPath => 'App data / logs';

  @override
  String get versionLabel => 'Version 1.0.0';

  @override
  String get noLogs => 'No recorded incident to export';

  @override
  String get exportLogs => 'Export latest incident';

  @override
  String get logsAccessFailed => 'Can\'t open logs. Check your file manager.';

  @override
  String get chooseVersion => 'Choose version';

  @override
  String get closeVersion => 'Close';

  @override
  String get filenameHints =>
      'Filename hints only. Check audio and subtitles during playback.';

  @override
  String get unknownSource => 'Unknown source';

  @override
  String get unnamedSource => 'Unnamed source';

  @override
  String get releaseTag => 'Release (unclassified)';

  @override
  String get encoderTag => 'Encoder';

  @override
  String get subtitleGroupTag => 'Subtitle group';

  @override
  String get sourceLabel => 'Source';

  @override
  String get minimize => 'Minimize';

  @override
  String get maximize => 'Maximize';

  @override
  String get restoreWindow => 'Restore';

  @override
  String get closeWindow => 'Close';

  @override
  String get apiGuideTitle => 'Get a TMDB key';

  @override
  String get apiGuideBody =>
      '1. Sign up or sign in at https://www.themoviedb.org/\n\n2. Go to Account settings → API. Use a desktop browser to apply.\n\n3. Enter your details and accept the terms.\n\n4. Return to Konata → TMDB API.\n\n5. Choose Access token for an API Read Access Token, or API Key for an API key. Don’t mix them up.\n\n6. Test the connection, then save. Keys stay in secure storage. Keep them private.\n\nAPI page: https://www.themoviedb.org/settings/api';

  @override
  String get openApiPage => 'Open API page';

  @override
  String get gotIt => 'Got it';

  @override
  String get browserCopyFailed => 'Can\'t open a browser. Copy the link below.';

  @override
  String get githubOpenFailed =>
      'Can\'t open a browser. Visit https://github.com/ClainSt/Konata';

  @override
  String get subtitleSimplified => 'Simplified Chinese';

  @override
  String get subtitleTraditional => 'Traditional Chinese';

  @override
  String get subtitleBilingual => 'Subs: Chinese / Japanese';

  @override
  String get subtitleAss => 'Subs: ASS';

  @override
  String get subtitlePgs => 'Subs: PGS';

  @override
  String get authMethod => 'Sign in with';

  @override
  String get accessToken => 'Token';

  @override
  String get closeTmdb => 'Close';

  @override
  String get enterCredentials => 'Enter a token or API key first.';

  @override
  String get connectionOk => 'Connected';

  @override
  String get credentialTestFailed =>
      'Connection failed. Check your key and network.';

  @override
  String get credentialSaveFailed => 'Couldn\'t save credentials. Try again.';

  @override
  String get secureCredentials =>
      'Stored securely. Switch credentials anytime.';

  @override
  String get metadataProviders =>
      'TMDB and Bangumi metadata. No key needed for Bangumi search.';

  @override
  String get testConnection => 'Test';

  @override
  String get save => 'Save';

  @override
  String get closeIdGuide => 'Close';

  @override
  String get idIntroTitle => 'TMDB IDs';

  @override
  String get idIntroBody =>
      'Add a TMDB ID to a title folder for a more precise match. IDs take priority during scans. No setup needed.';

  @override
  String get idFormatsTitle => 'Formats';

  @override
  String idFormats(
    String standard,
    String alternate,
    String brackets,
    String movie,
  ) {
    return 'Use $standard\nAlso accepted: $alternate, $brackets\nKeep the brackets. Case does not matter. For films, use $movie.';
  }

  @override
  String get idExampleTitle => 'Example';

  @override
  String idExample(String path) {
    return '$path\n\nTag each title folder, not the collection folder.';
  }

  @override
  String get idStepsTitle => 'Steps';

  @override
  String get idSteps =>
      '1. Find the numeric ID in the TMDB page URL. Check the title and type.\n2. Add the tag to the folder name yourself. Konata does not rename your files.\n3. Rescan the folder. To fix an existing match, search and link it on the details page.';

  @override
  String get idNotesTitle => 'Notes';

  @override
  String get idNotes =>
      '• A working TMDB key and connection are still required.\n• Use S01E01 for episodes and S00E01 for specials. A title ID does not identify episodes.\n• Match the TMDB year, or omit it if unsure.\n• Locked metadata and custom covers stay unchanged.\n• Missing or incomplete entries may need a manual match.';

  @override
  String get autoWatched => 'Mark watched';

  @override
  String get autoWatchedDescription =>
      'Mark a file watched after this much playback. Skips, pauses and replays add no extra credit. Manual status takes priority.';

  @override
  String get watchSettingsSaveFailed => 'Couldn\'t save. Try again.';

  @override
  String get progressSaveFailed => 'Couldn\'t save progress. Retrying.';

  @override
  String get apiAddress => 'API URL';

  @override
  String get imageAddress => 'Image URL';

  @override
  String get testApi => 'Test API';

  @override
  String get testImages => 'Test images';

  @override
  String get connectionDetails => 'Details';

  @override
  String get resetDefaults => 'Reset';

  @override
  String get officialServers => 'Official';

  @override
  String get closeMetadata => 'Close';

  @override
  String get serverNotice =>
      'Set API and image URLs separately. Bangumi uses a community mirror by default. HTTP is unencrypted.';

  @override
  String get videoOutputRecovered => 'Video output recovered.';

  @override
  String get autoFallback => 'Auto fallback';

  @override
  String get fallbackDescription =>
      'Use a backup server if requests fail. Tests use the entered URL.';

  @override
  String get allowCustomCredentials =>
      'Send credentials to custom TMDB HTTPS servers';

  @override
  String get notTested => 'Not tested';

  @override
  String get testing => 'Testing…';

  @override
  String get serverConnected => 'Connected';

  @override
  String get connectionPartial => 'Some features failed';

  @override
  String get serverSaveFailed =>
      'Couldn\'t save. Check URLs and storage access.';

  @override
  String get diagnosticCredentials => 'Add a TMDB key first';

  @override
  String get diagnosticAuth => 'Key rejected';

  @override
  String get diagnosticTimeout => 'Timed out';

  @override
  String get diagnosticTls => 'TLS failed';

  @override
  String get diagnosticNetwork => 'Network error';

  @override
  String get diagnosticInvalid => 'Invalid URL or response';

  @override
  String get diagnosticHttp => 'Server error';

  @override
  String get diagnosticFailed => 'Connection failed. Check URL and access.';

  @override
  String get audioTracks => 'Audio';

  @override
  String get subtitles => 'Subtitles';

  @override
  String get chooseSubtitles => 'Subtitles';

  @override
  String get chooseAudio => 'Audio tracks';

  @override
  String get subtitlesOff => 'Off';

  @override
  String get trackAuto => 'Auto';

  @override
  String get rewind10 => 'Back 10s';

  @override
  String get forward10 => 'Forward 10s';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get playbackFailed => 'Can\'t play. Check the file and source.';

  @override
  String get audioOff => 'Off';

  @override
  String get trackSwitchFailed => 'Couldn\'t switch tracks. Try again.';

  @override
  String get addMedia => 'Add media';

  @override
  String get localMedia => 'Local';

  @override
  String get networkMedia => 'Network';

  @override
  String get localFolder => 'Local folder';

  @override
  String get addLocalFolder => 'Choose a media folder';

  @override
  String get addLocalTitle => 'Add folder';

  @override
  String get addWebdav => 'Add WebDAV';

  @override
  String get addSmb => 'Add SMB';

  @override
  String get editSource => 'Edit source';

  @override
  String get sourceName => 'Name';

  @override
  String get smbUrl => 'SMB URL';

  @override
  String get webdavUrl => 'WebDAV URL';

  @override
  String get chooseFolder => 'Choose folder';

  @override
  String get chooseMediaFolder => 'Choose media folder';

  @override
  String get usernameOptional => 'Username (optional)';

  @override
  String get newPassword => 'New password (optional)';

  @override
  String get passwordWillClear => 'Saved password will be removed.';

  @override
  String get keepPassword =>
      'Leave blank to keep the password for the same user. Leave both blank for guest access.';

  @override
  String get undoClearPassword => 'Undo';

  @override
  String get clearSavedPassword => 'Clear saved password';

  @override
  String get sourceFieldsRequired => 'Enter a name and location.';

  @override
  String get invalidWebdav => 'Enter an HTTP or HTTPS URL.';

  @override
  String get invalidSmb => 'Enter smb://host/share.';

  @override
  String get anonymousCredentials =>
      'Leave both fields blank for guest access.';

  @override
  String get changeSourceTitle => 'Change location?';

  @override
  String get changeSourceBody =>
      'Titles, manual matches, progress and source ID stay. Rescan if the new folder has different files.';

  @override
  String get confirmChange => 'Change';

  @override
  String get sourceFolderMissing => 'The folder or share could not be found.';

  @override
  String get sourcePermissionDenied =>
      'Access denied. Check the folder permissions.';

  @override
  String get cancelScan => 'Cancel scan';

  @override
  String get scanCancelled => 'Scan cancelled';

  @override
  String get scanStopping => 'Stopping after the current operation…';

  @override
  String get sourceTestFailed =>
      'Connection failed. Check location, login and network.';

  @override
  String get sourceSaveFailed => 'Couldn\'t save source. Try again.';

  @override
  String get localAccessible => 'Folder found';

  @override
  String get localMissing => 'Folder not found';

  @override
  String get sourceConnectHint => 'Connect, then choose folders to scan.';

  @override
  String get connectionName => 'Name (optional)';

  @override
  String get folderPickerHint => 'Select Add to choose a folder.';

  @override
  String get smbUrlHint => 'SMB URL (smb://host/share)';

  @override
  String get usernameCreate => 'Username (optional)';

  @override
  String get smbUsername => 'Username (domain\\user supported)';

  @override
  String get passwordOptional => 'Password (optional)';

  @override
  String get showPassword => 'Show password';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get guestHint => 'Leave login fields blank for guest access.';

  @override
  String get add => 'Add';

  @override
  String get sourceAddFailed => 'Couldn\'t add source. Check the location.';

  @override
  String get scanProgress => 'Scan progress';

  @override
  String get folderSearch => 'Search folder (name or TMDB ID)';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get folderReadFailed =>
      'Couldn\'t read folder. Check location and connection.';

  @override
  String get parentFolder => '.. Up';

  @override
  String get fileLabel => 'File';

  @override
  String get help => 'Help';

  @override
  String get chooseScanHelpTitle => 'Choose folders';

  @override
  String get chooseScanHelp =>
      'Check title folders or whole collections to scan. Uncertain matches are flagged for review. Select a folder name to browse inside.';

  @override
  String get scanFolders => 'Scanning folders…';

  @override
  String get scanMetadata => 'Fetching metadata…';

  @override
  String get scanComplete => 'Scan complete';

  @override
  String get scanFailed => 'Scan failed';

  @override
  String get noScan => 'No scans yet';

  @override
  String get noScanHint => 'Choose folders to start a scan.';

  @override
  String get scanScope => 'Selected folders (including subfolders)';

  @override
  String get visitedFolders => 'Visited folders (direct video counts)';

  @override
  String get noFoldersRead => 'No folders read yet';

  @override
  String get scanningShort => 'Scanning';

  @override
  String sourceConnected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# items',
      one: '# item',
    );
    return 'Connected: $_temp0';
  }

  @override
  String browseSource(String name) {
    return 'Browse · $name';
  }

  @override
  String itemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# items',
      one: '# item',
    );
    return '$_temp0';
  }

  @override
  String videoCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# videos',
      one: '# video',
    );
    return '$_temp0';
  }

  @override
  String folderMatches(int found, int total) {
    return '$found of $total items';
  }

  @override
  String selectedScanFolders(int count) {
    return 'Selected ($count)';
  }

  @override
  String scanSelectedFolders(int count) {
    return 'Scan selected ($count)';
  }

  @override
  String scannedFolderCount(int count) {
    return 'Folders scanned: $count';
  }

  @override
  String indexedVideoCount(int count) {
    return 'Videos indexed: $count';
  }

  @override
  String scanMetadataCount(int done, int total) {
    return 'Metadata: $done/$total';
  }

  @override
  String scanSummary(int matched, int review, int failed) {
    return 'Matched: $matched · Review: $review · Failed: $failed';
  }

  @override
  String currentScanFolder(String path) {
    return 'Current folder: $path';
  }

  @override
  String get addSource => 'Add source';

  @override
  String get localDirectory => 'Local folder';

  @override
  String get browseScanFolders => 'Browse and choose scan folders';

  @override
  String get remove => 'Remove';

  @override
  String get removeSourceTitle => 'Remove source?';

  @override
  String get removeSourceBody => 'Remove the index only. Media files stay.';

  @override
  String get addSourceFirst => 'Add a source to get started';

  @override
  String get noMatchingTitles => 'No matches';

  @override
  String get searchTitles => 'Search works';

  @override
  String get closeSearch => 'Close search';

  @override
  String get manageHidden => 'Hidden titles';

  @override
  String sourceCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# sources',
      one: '# source',
    );
    return '$_temp0';
  }

  @override
  String workCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# titles',
      one: '# title',
    );
    return '$_temp0';
  }

  @override
  String get noHiddenTitles => 'No hidden titles';

  @override
  String get keepHidden => 'Keep hidden after rescans';

  @override
  String get restoreOnScan => 'Rescans restore this title';

  @override
  String get restoreTitle => 'Restore';

  @override
  String get titleNotFound => 'Title not found';

  @override
  String get scanBeforeRemove => 'Wait for the scan to finish.';

  @override
  String get removeWorkTitle => 'Remove title?';

  @override
  String get removeWorkBody =>
      'Remove from the library only. Files, manual matches and progress stay.';

  @override
  String get rescanRestoresHint => 'Otherwise, rescans restore it.';

  @override
  String get removeFromLibrary => 'Remove';

  @override
  String get removeWorkFailed => 'Couldn\'t remove title. Try again.';

  @override
  String get manualMatch => 'Match title';

  @override
  String get nameOrId => 'Title or TMDB ID';

  @override
  String get search => 'Search';

  @override
  String get searchFailed => 'Search failed. Check credentials and network.';

  @override
  String get bindFailed => 'Couldn\'t save match. Try again.';

  @override
  String get editMetadata => 'Edit details';

  @override
  String get workTitle => 'Title';

  @override
  String get year => 'Year';

  @override
  String get optional => 'Optional';

  @override
  String get synopsis => 'Synopsis';

  @override
  String get notLinked => 'Not linked';

  @override
  String get bangumiIds => 'Bangumi IDs';

  @override
  String get bangumiIdsHint =>
      'Separate IDs with commas, e.g. 302189, 331887. Saving locks the match and keeps the title together.';

  @override
  String get searchAndLink => 'Find match';

  @override
  String get invalidBangumiIds => 'Enter valid Bangumi IDs.';

  @override
  String get invalidTitleYear => 'Enter a title and valid year.';

  @override
  String get characterOrder => 'Character order';

  @override
  String get noCharactersYet => 'Load title details to see characters.';

  @override
  String get recropCover => 'Crop again';

  @override
  String get editCover => 'Edit poster';

  @override
  String get automaticCover => 'Use default';

  @override
  String get importImage => 'Import image';

  @override
  String get coverFailed =>
      'Couldn\'t save poster. Check the image and storage.';

  @override
  String get imageDecodeFailed => 'Can\'t open this image.';

  @override
  String get cropFailed => 'Couldn\'t export crop. Try again.';

  @override
  String get cropPoster => 'Crop poster · 2:3';

  @override
  String get cropHint =>
      'Drag to move. Scroll or pinch to zoom. The frame is your poster.';

  @override
  String get lowResImage => 'Low-resolution image. No upscaling.';

  @override
  String get reset => 'Reset';

  @override
  String get saving => 'Saving…';

  @override
  String get confirmSave => 'Save';

  @override
  String get mainFeature => 'Episodes';

  @override
  String get extraFiles => 'Extras';

  @override
  String get allExtras => 'All';

  @override
  String get otherExtra => 'Other';

  @override
  String get unnamedVideo => 'Untitled video';

  @override
  String get unnamedWork => 'Untitled';

  @override
  String get cast => 'Cast';

  @override
  String get crew => 'Crew';

  @override
  String get characters => 'Characters';

  @override
  String get collapseList => 'Less';

  @override
  String get fullList => 'Full list';

  @override
  String get noExtras => 'No extras';

  @override
  String get noLinkedEpisodes => 'No linked episodes';

  @override
  String get backToLibrary => 'Back to library';

  @override
  String get moreActions => 'More';

  @override
  String get noMainFeature => 'No episodes';

  @override
  String get startPlayback => 'Play';

  @override
  String get noSynopsis => 'No synopsis';

  @override
  String get collapseSynopsis => 'Less';

  @override
  String get expandSynopsis => 'Read more';

  @override
  String get unwatchedStatus => 'Unwatched';

  @override
  String get commercial => 'Commercial';

  @override
  String get promoVideo => 'Promo';

  @override
  String get cleanOpening => 'Clean opening';

  @override
  String get cleanEnding => 'Clean ending';

  @override
  String get discMenu => 'Disc menu';

  @override
  String get specialEpisode => 'Special';

  @override
  String episodeLabel(int number) {
    return 'Ep. $number';
  }

  @override
  String detailEpisodeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# episodes',
      one: '# episode',
    );
    return '$_temp0';
  }

  @override
  String detailVersionCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# versions',
      one: '# version',
    );
    return '$_temp0';
  }

  @override
  String resumeEpisode(String episode) {
    return 'Resume $episode';
  }

  @override
  String get resumePlayback => 'Resume';

  @override
  String get removeTitleAction => 'Remove';

  @override
  String seekSeconds(int count) {
    return '$count s';
  }

  @override
  String get tmdbOpenFailed =>
      'Can\'t open a browser. Visit https://www.themoviedb.org';

  @override
  String get manualEdit => 'Match episodes';

  @override
  String get chooseSeason => 'Choose season';

  @override
  String get chooseEpisode => 'Choose episode';

  @override
  String get keepMatch => 'Keep match';

  @override
  String get mappingHint =>
      'Choose a title and season, then match each file. To change titles, match every file.';

  @override
  String get mappingFailed => 'Couldn’t save. Check matches and try again.';

  @override
  String get loadingMatches => 'Loading…';

  @override
  String get playbackStats => 'Stats';

  @override
  String get chapters => 'Chapters';

  @override
  String get noChapters => 'No chapters in this file';

  @override
  String get chapterReadFailed => 'Couldn’t read chapters. Try again.';

  @override
  String get statsUnavailable => 'Unknown';

  @override
  String get subtitleJapanese => 'Japanese';

  @override
  String get subtitleChinese => 'Chinese';

  @override
  String get losslessAudio => 'Lossless';

  @override
  String get externalTrack => 'External';

  @override
  String get statVideo => 'Video codec';

  @override
  String get statResolution => 'Resolution';

  @override
  String get statFps => 'Frame rate';

  @override
  String get statOutputFps => 'Output FPS';

  @override
  String get statHwdec => 'Hardware decode';

  @override
  String get statDropped => 'Dropped frames';

  @override
  String get statDecoderDropped => 'Decoder drops';

  @override
  String get statAudio => 'Audio codec';

  @override
  String get statSampleRate => 'Sample rate (Hz)';

  @override
  String get statChannels => 'Channels';

  @override
  String get statBitrate => 'Audio bitrate (bps)';

  @override
  String get statCache => 'Buffer (s)';

  @override
  String get statAvsync => 'A/V offset (s)';

  @override
  String get timelinePreview => 'Timeline preview';

  @override
  String get previewOn => 'Timeline preview on';

  @override
  String get previewOff => 'Timeline preview off';

  @override
  String get subtitleSimplifiedJapanese => 'Chinese (Simplified) + Japanese';

  @override
  String get subtitleTraditionalJapanese => 'Chinese (Traditional) + Japanese';

  @override
  String get containedTrack => 'Muxed';

  @override
  String get importSubtitle => 'Import subtitles';

  @override
  String trackNumber(int number) {
    return 'Track $number';
  }

  @override
  String get exportLibraryBackup => 'Export library backup';

  @override
  String get exportLibraryBackupDescription =>
      'Exports library data, viewing history and custom covers; excludes videos and saved credentials.';

  @override
  String get exportLibraryBackupDone => 'Backup exported';

  @override
  String get exportLibraryBackupFailed => 'Backup export failed';

  @override
  String get exportLibraryBackupTooLarge =>
      'Backup is too large to save on this device';

  @override
  String get inspectLibraryBackup => 'Inspect backup';

  @override
  String get inspectLibraryBackupDescription =>
      'Verify a Konata backup without importing or changing data.';

  @override
  String get inspectLibraryBackupFailed => 'Backup validation failed';

  @override
  String get playerSettings => 'Player';

  @override
  String get mpvConfiguration => 'Native MPV configuration';

  @override
  String get mpvEnable => 'Use custom mpv.conf and input.conf';

  @override
  String get mpvEnableDetail =>
      'Only use trusted files. Konata reads mpv.conf and input.conf before each playback.';

  @override
  String get mpvNextPlayback => 'Changes take effect when a new player opens.';

  @override
  String get mpvEdit => 'Edit';

  @override
  String get mpvImport => 'Import file';

  @override
  String get mpvReset => 'Restore empty default';

  @override
  String get mpvFolderReadError =>
      'Cannot read the configuration folder. Check the files or choose the folder again in player settings.';

  @override
  String get mpvUseInternal => 'Use in-app configuration';

  @override
  String get fullscreen => 'Enter fullscreen';

  @override
  String get exitFullscreen => 'Exit fullscreen';

  @override
  String get mpvOpenDirectory => 'Choose configuration folder';

  @override
  String get mpvError => 'MPV settings operation failed';

  @override
  String get mpvSave => 'Save';

  @override
  String get backupPreviewCounts =>
      'Works / Files / Sources / History / Covers';

  @override
  String get confirmEpisodeIdentity => 'Confirm episode identity';

  @override
  String get revokeEpisodeIdentity => 'Remove identity confirmation';

  @override
  String get watchStateConflict => 'Conflicting watched states';

  @override
  String get confirmEpisodeDescription =>
      'Check the title, season and episode. Only confirm if this file matches.';

  @override
  String get historyEventsRetained =>
      'Watch events are kept separately; deleting resume history does not mark an episode unwatched or delete events.';

  @override
  String get bangumiEpisodeMapping => 'Bangumi episode';

  @override
  String get bangumiSubjectId => 'Subject ID';

  @override
  String get bangumiEpisodeId => 'Episode ID';

  @override
  String get bangumiEpisodeType => 'Episode type';

  @override
  String get bangumiMainStory => 'Main story';

  @override
  String get verifyBangumiEpisode => 'Check episode';

  @override
  String get bangumiMappingDescription =>
      'Check the subject, episode title, number and type. Numbering may differ from TMDB. This only saves a match.';

  @override
  String get bangumiMappingFailed =>
      'Episode check failed. Check the IDs and type, then retry.';

  @override
  String get revokeBangumiMapping => 'Remove episode match';

  @override
  String get statMpvVersion => 'MPV version';

  @override
  String get statHwdecSetting => 'Decode setting';

  @override
  String get statPixelFormat => 'Decoded pixel format';

  @override
  String get statUnderlyingPixelFormat => 'Underlying pixel format';

  @override
  String get statColorMatrix => 'Color matrix';

  @override
  String get statColorPrimaries => 'Color primaries';

  @override
  String get statTransferFunction => 'Transfer function';

  @override
  String get statColorRange => 'Color range';

  @override
  String get statVideoOutput => 'Video output';

  @override
  String get statFilteredWidth => 'Filtered video width';

  @override
  String get statFilteredHeight => 'Filtered video height';

  @override
  String get statCachePaused => 'Paused for cache';

  @override
  String get statSourceDepth => 'Decoded component depth (known formats)';

  @override
  String get statTextureSize => 'Flutter texture size';

  @override
  String get statFilteredDepth => 'Component depth after filters';

  @override
  String get statTargetDepth => 'MPV target depth (reported)';

  @override
  String get statTargetPrimaries => 'MPV target primaries';

  @override
  String get statTargetTransfer => 'MPV target transfer function';

  @override
  String get statPresentationDepth => 'Final presentation depth (unmeasured)';

  @override
  String get statDecodedAudioFormat => 'Decoded audio sample format';

  @override
  String get statOutputAudioFormat => 'Audio API sample format';

  @override
  String get statOutputSampleRate => 'Audio API sample rate';

  @override
  String get statOutputChannels => 'Audio API channel layout';

  @override
  String get statAudioOutput => 'Audio output';

  @override
  String get restoreLibraryBackup => 'Restore from backup';

  @override
  String get restoreLibraryBackupDescription =>
      'Preview and restore your library, history, custom covers and basic settings from a ZIP backup.';

  @override
  String get restoreLibraryBackupWarning =>
      'This replaces your current library and playback history; it does not merge them. A backup of current data is saved first. Failed changes are rolled back.\n\nMedia files are not included. Re-enter source passwords. On another device, select and authorize local folders again in Edit source. Restore does not scan or connect to sources.';

  @override
  String get restoringLibraryBackup => 'Restoring, please wait…';

  @override
  String get restoreLibraryBackupDone =>
      'Restore complete. Edit sources to reconnect folders or re-enter passwords if needed.';

  @override
  String get restoreLibraryBackupFailed =>
      'Restore did not complete. Check the backup and available storage, then try again.';

  @override
  String get restoreLibraryBackupBusy =>
      'Wait for scanning to finish before restoring a backup.';

  @override
  String get previousLibraryBackup => 'Backups before restore';

  @override
  String get previousLibraryBackupDescription =>
      'Preview and restore either of the last two automatic backups.';

  @override
  String get noPreviousLibraryBackup =>
      'No automatic backup has been created yet.';

  @override
  String get restoreCurrentLibrary =>
      'Current library (works / files / sources)';

  @override
  String get extensions => 'Extensions';

  @override
  String get extensionsDescription =>
      'Enable optional features here. Their settings appear under Scraping services when enabled. Turning a feature off stops its requests and releases its temporary resources.';

  @override
  String get characterDetails => 'Characters and voice actors';

  @override
  String get characterDetailsDescription =>
      'Show Bangumi character and voice actor details on title pages.';

  @override
  String get voiceActorPhotos => 'Use voice actor photos';

  @override
  String get creditsDetails => 'Cast and crew';

  @override
  String get creditsDetailsDescription =>
      'Show TMDB cast and crew on live-action title pages.';

  @override
  String get creditsServiceSettings =>
      'Uses the shared TMDB credentials. Open API settings.';

  @override
  String get optionalFeatureFailed =>
      'Could not load or save this feature. Please retry.';

  @override
  String get optionalNoResults => 'No details available.';

  @override
  String get animationCategory => 'Animation';

  @override
  String get liveActionCategory => 'Live action';

  @override
  String get featureOff => 'Off';

  @override
  String get voiceActors => 'Voice actors';

  @override
  String get sage => 'Sage';

  @override
  String get allWorks => 'All titles';

  @override
  String compactWorkCount(int count) {
    return '$count';
  }

  @override
  String get bangumiPeopleData => 'Bangumi characters / voice actors';

  @override
  String get tmdbPeopleData => 'TMDB people';

  @override
  String get peopleBar => 'Character row';

  @override
  String get peopleFallbackTmdb => 'When Bangumi is off, use TMDB people.';

  @override
  String get peopleFallbackHidden =>
      'When Bangumi is off, hide the character row.';

  @override
  String get historySelectAll => 'Select all';

  @override
  String get historyDeselectAll => 'Deselect all';

  @override
  String historySelectionCount(int count) {
    return '$count selected';
  }

  @override
  String deleteHistorySelectionQuestion(int count) {
    return 'Delete $count selected records?';
  }

  @override
  String get imageCache => 'Image cache';

  @override
  String get measuringCache => 'Measuring…';

  @override
  String get cacheSizeUnavailable => 'Unable to measure';

  @override
  String get openCacheDirectory => 'Open cache folder';

  @override
  String get cacheDirectoryUnavailable => 'Cannot open the cache folder.';

  @override
  String get detailBackdrop => 'Detail page background';

  @override
  String get cacheSettingFailed => 'Could not save this setting.';

  @override
  String get nameOrBangumiId => 'Name or Bangumi ID';

  @override
  String get unclassified => 'Unclassified';

  @override
  String get assignToWork => 'Assign to title';

  @override
  String get workName => 'Title name';

  @override
  String get createClassification => 'Create title with this name';

  @override
  String get classificationHint =>
      'Only library assignments change; original files stay in place. Select files from one source, then assign them to an existing or new title.';

  @override
  String get selectSourceFiles => 'Select all from this source';
}
