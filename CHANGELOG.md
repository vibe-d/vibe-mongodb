# Changelog

## v1.1.1

### Fixed

- Dead connections evicted from a pool are now closed instead of only being
  dropped from it. An evicted connection previously kept its socket open for
  the life of the process, so every server restart leaked one file descriptor
  per pooled connection.

### Changed

- `MongoConnection.disconnect` releases its stream and output buffer on every
  path, including when the socket is already locally disconnected.

### Added

- The dead-connection test now opens several pooled connections concurrently
  and asserts the process holds no more file descriptors after a server
  restart than before it.

## v1.1.0

### Added

- `GridFSBucket` streaming uploads: resumable uploads backed by a pending
  files document, so an interrupted upload can continue instead of restarting.
- `GridFSBucket` test coverage for ranged reads and streaming upload
  validation.
