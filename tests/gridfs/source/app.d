/// Exercises GridFSBucket's buffer round-trip against a real mongod.
/// A multi-chunk buffer uploaded via uploadFromBuffer must come back byte-identical
/// through downloadToBuffer.

module app;

import vibe.core.log;
import vibe.data.bson;
import vibe.db.mongo.mongo;

import std.conv : to;
import std.exception : assertThrown;

void runTest(ushort port)
{
	auto client = connectMongoDB("mongodb://127.0.0.1:" ~ port.to!string ~ "/");
	scope (exit) client.cleanupConnections();
	auto db = client.getDatabase("gridfs_test");

	// Force multiple chunks out of a small buffer: 250 bytes / 100 = 3 chunks.
	GridFSBucketOptions options;
	options.chunkSizeBytes = 100;
	auto bucket = GridFSBucket(db, options);

	// Clear any prior files/chunks state so reruns stay idempotent.
	try db["fs.files"].drop; catch (Exception) {}
	try db["fs.chunks"].drop; catch (Exception) {}

	ubyte[] data;
	foreach (i; 0 .. 250)
		data ~= cast(ubyte)(i % 256);

	auto id = bucket.uploadFromBuffer("hello.bin", data);
	logInfo("uploaded %s bytes as %s", data.length, id.to!string);

	auto got = bucket.downloadToBuffer(id);
	assert(got == data, "downloaded buffer did not match the uploaded bytes");
	logInfo("buffer round-trip OK: %s bytes across multiple chunks", got.length);

	auto missingId = BsonObjectID.generate();
	assertThrown(bucket.downloadToBuffer(missingId));
	logInfo("missing-id download rejected as required");

	// Ranged reads fetch only the covering chunks and slice exactly.
	assert(bucket.readRange(id, 0, 10) == data[0 .. 10], "range at the file start");
	assert(bucket.readRange(id, 95, 10) == data[95 .. 105], "range crossing a chunk boundary");
	assert(bucket.readRange(id, 240, 10) == data[240 .. 250], "range at the file end");
	assert(bucket.readRange(id, 120, 0) == null, "zero-length range reads nothing");
	assertThrown(bucket.readRange(id, 245, 10), "range past the end is rejected");
	assertThrown(bucket.readRange(missingId, 0, 1), "range read of a missing file is rejected");

	auto fileDoc = db["fs.files"].findOne(["_id": Bson(id)]);
	assert(bucket.readRange(fileDoc, 95, 10) == data[95 .. 105], "range read via a cached files document");
	logInfo("ranged reads OK");

	// The newest file wins a filename lookup; unknown names come back null.
	auto secondId = bucket.uploadFromBuffer("hello.bin", data[0 .. 7]);
	auto newest = bucket.findFileByName("hello.bin");
	assert(!newest.isNull, "a stored filename is found");
	assert(newest["_id"].get!BsonObjectID == secondId, "the newest upload wins the name lookup");
	assert(bucket.findFileByName("no-such-file.bin").isNull, "an unknown filename comes back null");
	logInfo("filename lookup OK");

	// A streamed upload split across many put() calls round-trips byte-identical.
	ubyte[] streamed;
	foreach (i; 0 .. 1050)
		streamed ~= cast(ubyte)(i * 7 % 256);

	auto upload = bucket.openUploadStream("streamed.bin");
	foreach (sliceStart; 0 .. 35)
		upload.put(streamed[sliceStart * 30 .. sliceStart * 30 + 30]);
	auto streamedId = upload.finish();

	assert(bucket.downloadToBuffer(streamedId) == streamed, "streamed upload round-trips");
	assert(db["fs.chunks"].countDocuments(["files_id": Bson(streamedId)]) == 11,
		"1050 bytes at chunk size 100 store 11 chunks");
	assertThrown(upload.finish(), "finishing a closed stream is rejected");
	logInfo("streaming upload OK");

	// An aborted upload leaves no chunks behind and no visible file.
	auto doomed = bucket.openUploadStream("doomed.bin");
	doomed.put(streamed[0 .. 500]);
	doomed.abort();
	assert(db["fs.chunks"].countDocuments(["files_id": Bson(doomed.filesId)]) == 0,
		"aborting removes the chunks already inserted");
	assert(bucket.findFileByName("doomed.bin").isNull, "an aborted upload never becomes visible");
	logInfo("upload abort OK");

	// Deleting removes the files document and every chunk.
	bucket.deleteFile(streamedId);
	assert(bucket.findFileByName("streamed.bin").isNull, "a deleted file is gone from the files collection");
	assert(db["fs.chunks"].countDocuments(["files_id": Bson(streamedId)]) == 0,
		"a deleted file leaves no chunks");
	logInfo("delete OK");

	logInfo("gridfs harness passed");
}

void main(string[] args)
{
	setLogLevel(LogLevel.info);
	ushort port = args.length > 1
		? args[1].to!ushort
		: MongoClientSettings.defaultPort;
	runTest(port);
}
