# Changelog

## v1.1.0

### Added

- `GridFSBucket` streaming uploads: resumable uploads backed by a pending
  files document, so an interrupted upload can continue instead of restarting.
- `GridFSBucket` test coverage for ranged reads and streaming upload
  validation.
