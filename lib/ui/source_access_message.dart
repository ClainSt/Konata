import '../core/sources.dart';
import '../l10n/app_localizations.dart';

String sourceAccessMessage(AppLocalizations l, SourceAccessProblem issue) =>
    switch (issue) {
      SourceAccessProblem.authentication => l.diagnosticAuth,
      SourceAccessProblem.permission => l.sourcePermissionDenied,
      SourceAccessProblem.path => l.sourceFolderMissing,
      SourceAccessProblem.timeout => l.diagnosticTimeout,
      SourceAccessProblem.network => l.diagnosticNetwork,
      SourceAccessProblem.tls => l.diagnosticTls,
      SourceAccessProblem.unknown => l.folderReadFailed,
    };
