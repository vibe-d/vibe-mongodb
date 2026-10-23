# Changelog

## v2.0.0

### Breaking

- The package moved to the vibe-d organization and is now called `vibe-mongodb`. It replaces the
  driver that used to ship inside vibe.d as `vibe-d:mongodb`, which now forwards to this package.
- Modules are back under their original `vibe.db.mongo` names. Code written against
  `vibe-mongodriver` needs its `vibe.db.mongodriver` imports renamed (see the README). Code written
  against `vibe-d:mongodb` compiles unchanged.
- `InsertOneResult.insertedId` is a `BsonObjectID` again and `UpdateResult.upsertedIds` a
  `BsonObjectID[]`, as in `vibe-d:mongodb`. Ids of any other BSON type are reported as
  `BsonObjectID.init` there. Read the new `insertedIdValue` and `upsertedIdValues` fields for the
  verbatim id of any type.

### Added

- `InsertOneResult.insertedIdValue` and `UpdateResult.upsertedIdValues`, carrying the inserted or
  upserted `_id` as `Bson`.

### Fixed

- `insertOne` reports the id of a document that already had an `_id`, not only of generated ones.
- Upserting a document whose `_id` is not an ObjectID no longer throws while reading the result, a
  bug still present in `vibe-d:mongodb`.

### Changed

- The connection handshake reports the driver name as `vibe.db.mongo` again, matching what servers
  saw from `vibe-d:mongodb`.

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
