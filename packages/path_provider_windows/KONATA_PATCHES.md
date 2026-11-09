# Konata portable paths

Based on Flutter path_provider_windows 2.3.0; upstream LICENSE retained.
The Windows application support and cache directories resolve relative to the
executable as `userdata/` and `cache/`; temporary files use `cache/tmp/`.
This small local adapter also covers shared_preferences_windows, which creates
its own PathProviderWindows instead of using PathProviderPlatform.instance.
Avoid using its testing-only path injection API or duplicating preferences IO.

First startup copies the previous CompanyName/ProductName roaming directory
through a staging directory, then renames it into place. Existing portable data
wins. SQLite files are locked during import; old data is never removed. No silent
AppData fallback is allowed. Regression coverage: test/portable_paths_test.dart.
Locks include SQLite's high-offset lock bytes and WAL/SHM/journal companions;
tests exercise a real open WAL database and verify the closed copy can be read.
