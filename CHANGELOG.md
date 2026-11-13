# Changelog

All notable changes to this project will be documented in this file.


## [1.0.2] - 2026-11-13

### Fixed
- A space typed by mistake before or after the username or password no
  longer makes the server refuse the login.
- "Too many attempts" (HTTP 429) now has its own message instead of a bare
  error code.
- Automatic checks pause after a refused login or a 429, instead of retrying
  every few minutes and keeping the server's block going. They resume when
  the server settings change or a check succeeds.

## [1.0.1] - 2026-11-04

### Changed
- Uses less memory: the sync code loads the first time a check runs, not
  when KOReader starts.

## [1.0.0] - 2026-10-30

### Added
- First release: an asynchronous drop box for books over WebDAV. Books
  dropped into a remote folder are fetched when the reader is online, saved
  locally and removed from the folder.
- Automatic checks after startup and when Wi-Fi connects (at most every
  5 minutes, deferred while a book is open), and a manual *Check now*.
- Safe downloads: `.part` file, size check against the listing and
  `Content-Length`, ZIP check for EPUB/CBZ/DOCX, PDF trailer check, no
  overwrite on name collision, remote `DELETE` only once the book is in
  place; failed deletes are remembered and retried, never re-downloaded.
- Settings: server, credentials, drop folder (created if missing), local
  folder, file types; import from KOReader's Cloud storage; *Test
  connection* with clear error messages; Koofr shortcut and setup help.
- French, Spanish and German translations.
