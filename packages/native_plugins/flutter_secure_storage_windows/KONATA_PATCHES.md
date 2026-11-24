# Konata portable credentials

The existing local FFI adapter now stores DPAPI-protected ciphertext beneath the
portable application support directory, rather than writing Credential Manager.
Read-only legacy migration occurs once per requested key; encrypted tombstones
prevent deleted keys from reappearing. The old credentials remain as rollback.
DPAPI retains Windows account protection: moving the folder on the same account
works; a different Windows account/machine requires entering credentials again.
Unreadable ciphertext is retained and treated as unavailable; an explicit write
can replace it. A failed decrypt never triggers a legacy re-import over that file.
No plaintext fallback or new crypto library is introduced. Tests use synthetic
values only in test/portable_paths_test.dart.
