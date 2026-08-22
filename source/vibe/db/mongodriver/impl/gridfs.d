/**
	MongoDB GridFS API definitions.

	Copyright: © 2026 Szabo Bogdan
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Szabo Bogdan
*/
module vibe.db.mongodriver.impl.gridfs;

import vibe.data.bson;

import std.array : array;
import std.algorithm : map;
import std.range : chunks, enumerate;
import std.datetime.systime : Clock;
import std.exception : enforce;

@safe:

/// configures a GridFS bucket; bucketName mirrors the Node driver option
struct GridFSBucketOptions
{
	string bucketName = "fs";

	/// default chunk size in bytes; mirrors the Node driver's 255 KiB default
	int chunkSizeBytes = 261120;
}

/// name of the files collection for the given bucket
string filesCollectionName(in GridFSBucketOptions options)
{
	return options.bucketName ~ ".files";
}

/// name of the chunks collection for the given bucket
string chunksCollectionName(in GridFSBucketOptions options)
{
	return options.bucketName ~ ".chunks";
}

/// default GridFS bucket options name the collections fs.files and fs.chunks
unittest
{
	GridFSBucketOptions options = GridFSBucketOptions.init;
	assert(filesCollectionName(options) == "fs.files");
	assert(chunksCollectionName(options) == "fs.chunks");
}

/// default GridFS bucket options chunk size is 261120 bytes
unittest
{
	assert(GridFSBucketOptions.init.chunkSizeBytes == 261120);
}

/// builds a single GridFS chunk document for the slice at index n
private Bson gridfsChunkDocument(BsonObjectID filesId, int n, scope const(ubyte)[] slice)
{
	Bson chunk = Bson.emptyObject;
	chunk["_id"] = Bson(BsonObjectID.generate());
	chunk["files_id"] = Bson(filesId);
	chunk["n"] = Bson(n);
	chunk["data"] = Bson(BsonBinData(BsonBinData.Type.generic, slice.idup));
	return chunk;
}

/// splits data into GridFS chunk documents of at most chunkSize bytes each
Bson[] gridfsChunkDocuments(BsonObjectID filesId, scope const(ubyte)[] data, int chunkSize)
{
	enforce(chunkSize > 0, "GridFS chunkSize must be positive");

	return data.chunks(chunkSize)
		.enumerate
		.map!(indexed => gridfsChunkDocument(filesId, cast(int) indexed.index, indexed.value))
		.array;
}

/// chunking with a non-positive chunk size throws
unittest
{
	import std.exception : assertThrown;

	auto filesId = BsonObjectID.generate();

	assertThrown!Exception(gridfsChunkDocuments(filesId, [ubyte(1), ubyte(2), ubyte(3)], 0));
}

/// chunking empty data yields zero chunks (an empty file is a files document with no chunks)
unittest
{
	const(ubyte)[] empty;
	auto chunks = gridfsChunkDocuments(BsonObjectID.generate(), empty, 255);

	assert(chunks.length == 0, "empty data produces no chunk documents");
}

/// chunking bytes shorter than the chunk size yields one chunk at index zero
unittest
{
	auto filesId = BsonObjectID.generate();
	ubyte[] data = [1, 2, 3];

	auto chunks = gridfsChunkDocuments(filesId, data, 255);

	assert(chunks.length == 1);
	assert(chunks[0]["n"].get!int == 0);
	assert(chunks[0]["files_id"].get!BsonObjectID == filesId);
	assert(chunks[0]["data"].get!BsonBinData.rawData == data);
}

/// chunking a buffer longer than the chunk size yields ordered chunks with a short final chunk
unittest
{
	auto filesId = BsonObjectID.generate();
	ubyte[] data = [1, 2, 3, 4, 5];

	auto chunks = gridfsChunkDocuments(filesId, data, 2);

	assert(chunks.length == 3);

	assert(chunks[0]["n"].get!int == 0);
	assert(chunks[1]["n"].get!int == 1);
	assert(chunks[2]["n"].get!int == 2);

	assert(chunks[0]["data"].get!BsonBinData.rawData == cast(ubyte[])[1, 2]);
	assert(chunks[1]["data"].get!BsonBinData.rawData == cast(ubyte[])[3, 4]);
	assert(chunks[2]["data"].get!BsonBinData.rawData == cast(ubyte[])[5]);

	assert(chunks[0]["files_id"].get!BsonObjectID == filesId);
	assert(chunks[1]["files_id"].get!BsonObjectID == filesId);
	assert(chunks[2]["files_id"].get!BsonObjectID == filesId);
}

/// builds the <bucket>.files metadata document for a stored file
Bson gridfsFilesDocument(BsonObjectID filesId, string filename, long length, int chunkSize)
{
	Bson doc = Bson.emptyObject;
	doc["_id"] = Bson(filesId);
	doc["length"] = Bson(length);
	doc["chunkSize"] = Bson(chunkSize);
	doc["filename"] = Bson(filename);
	doc["uploadDate"] = Bson(BsonDate(Clock.currTime));
	return doc;
}

/// flags a files document whose chunks are still being written
enum gridfsIncompleteField = "incomplete";

/// the files document of an unfinished upload, written before any chunk so a killed
/// process leaves a resumable record instead of orphaned chunks
Bson gridfsPendingFilesDocument(BsonObjectID filesId, string filename, int chunkSize)
{
	Bson doc = gridfsFilesDocument(filesId, filename, 0, chunkSize);
	doc[gridfsIncompleteField] = Bson(true);
	return doc;
}

/// a pending files document is flagged and starts empty
unittest
{
	auto filesId = BsonObjectID.generate();
	auto doc = gridfsPendingFilesDocument(filesId, "planet.pmtiles", 65536);

	assert(doc["_id"].get!BsonObjectID == filesId);
	assert(doc["filename"].get!string == "planet.pmtiles");
	assert(doc["length"].get!long == 0);
	assert(doc["chunkSize"].get!int == 65536);
	assert(doc[gridfsIncompleteField].get!bool == true);
}

/// the files document carries the file id, length, chunk size, and filename
unittest
{
	auto filesId = BsonObjectID.generate();

	auto doc = gridfsFilesDocument(filesId, "report.pdf", 1048576L, 261120);

	assert(doc["_id"].get!BsonObjectID == filesId);
	assert(doc["length"].get!long == 1048576L);
	assert(doc["chunkSize"].get!int == 261120);
	assert(doc["filename"].get!string == "report.pdf");
}

/// the files document is stamped with an upload date of BSON date type
unittest
{
	auto doc = gridfsFilesDocument(BsonObjectID.generate(), "f.bin", 10L, 4);

	assert(doc["uploadDate"].type == Bson.Type.date);
}

/// concatenates GridFS chunk documents into the original byte buffer
ubyte[] gridfsAssembleChunks(scope Bson[] chunks)
{
	import std.algorithm : sort;
	import std.conv : to;

	auto ordered = chunks.dup;
	ordered.sort!((a, b) => a["n"].get!int < b["n"].get!int);
	ubyte[] data;
	foreach (i, chunk; ordered)
	{
		enforce(chunk["n"].get!int == cast(int) i,
			"GridFS chunk " ~ i.to!string ~ " is missing");
		data ~= chunk["data"].get!BsonBinData.rawData;
	}
	return data;
}

/// concatenates GridFS chunks and validates the total against the files document's `length`,
/// catching missing trailing chunks (the interior-gap check alone would silently truncate).
ubyte[] gridfsAssembleChunks(scope Bson[] chunks, long expectedLength)
{
	import std.conv : to;

	auto data = gridfsAssembleChunks(chunks);
	enforce(cast(long) data.length == expectedLength,
		"GridFS file is truncated: assembled " ~ data.length.to!string
			~ " bytes but the files document declares " ~ expectedLength.to!string);
	return data;
}

/// assembling chunk documents reconstructs the original bytes
unittest
{
	auto filesId = BsonObjectID.generate();
	ubyte[] data = [1, 2, 3, 4, 5];

	auto chunks = gridfsChunkDocuments(filesId, data, 2);
	auto assembled = gridfsAssembleChunks(chunks);

	assert(assembled == data);
}

/// assembling chunks with a missing index throws
unittest
{
	import std.exception : assertThrown;
	import std.algorithm.mutation : remove;

	auto filesId = BsonObjectID.generate();
	ubyte[] data = [1, 2, 3, 4, 5];

	auto chunks = gridfsChunkDocuments(filesId, data, 2);
	chunks = chunks.remove(1);

	assertThrown(gridfsAssembleChunks(chunks));
}

/// assembling chunks supplied out of order reconstructs the original bytes
unittest
{
	import std.algorithm : reverse;

	auto filesId = BsonObjectID.generate();
	ubyte[] data = [1, 2, 3, 4, 5];

	auto chunks = gridfsChunkDocuments(filesId, data, 2);
	chunks.reverse;

	auto assembled = gridfsAssembleChunks(chunks);

	assert(assembled == data);
}

/// assembling all chunks whose total matches the files length returns the bytes
unittest
{
	auto filesId = BsonObjectID.generate();
	ubyte[] data = [1, 2, 3, 4, 5, 6];

	auto chunks = gridfsChunkDocuments(filesId, data, 2);

	assert(gridfsAssembleChunks(chunks, cast(long) data.length) == data);
}

/// assembling chunks shorter than the files length throws (missing trailing chunks, not just interior gaps)
unittest
{
	import std.exception : assertThrown;

	auto filesId = BsonObjectID.generate();
	ubyte[] data = [1, 2, 3, 4, 5, 6];

	auto chunks = gridfsChunkDocuments(filesId, data, 2); // 3 chunks of 2 bytes
	auto missingTrailing = chunks[0 .. 2];                // drop the LAST chunk: 4 bytes, no interior gap

	assertThrown(gridfsAssembleChunks(missingTrailing, cast(long) data.length),
		"a file missing its trailing chunk is rejected, not silently truncated");
}

/// The inclusive chunk index interval [first, last] that covers a byte range.
struct GridFSChunkSpan
{
	int first;
	int last;
}

/// computes which chunk indexes cover the byte range [offset, offset + length)
GridFSChunkSpan gridfsChunkSpan(long offset, long length, int chunkSize)
{
	enforce(chunkSize > 0, "GridFS chunkSize must be positive");
	enforce(offset >= 0, "GridFS range offset must not be negative");
	enforce(length > 0, "GridFS range length must be positive");

	return GridFSChunkSpan(cast(int)(offset / chunkSize), cast(int)((offset + length - 1) / chunkSize));
}

/// a range inside the first chunk spans only chunk zero
unittest
{
	assert(gridfsChunkSpan(0, 10, 100) == GridFSChunkSpan(0, 0));
	assert(gridfsChunkSpan(90, 10, 100) == GridFSChunkSpan(0, 0));
}

/// a range crossing a chunk boundary spans both chunks
unittest
{
	assert(gridfsChunkSpan(90, 11, 100) == GridFSChunkSpan(0, 1));
	assert(gridfsChunkSpan(250, 100, 100) == GridFSChunkSpan(2, 3));
}

/// a range starting exactly on a chunk boundary starts at that chunk
unittest
{
	assert(gridfsChunkSpan(200, 1, 100) == GridFSChunkSpan(2, 2));
}

/// a zero-length or negative range is rejected
unittest
{
	import std.exception : assertThrown;

	assertThrown!Exception(gridfsChunkSpan(0, 0, 100));
	assertThrown!Exception(gridfsChunkSpan(-1, 10, 100));
	assertThrown!Exception(gridfsChunkSpan(0, 10, 0));
}

/// slices the byte range [offset, offset + length) out of the chunk documents that
/// cover its span; `chunks` must be exactly the covering chunks, any order
ubyte[] gridfsAssembleRange(scope Bson[] chunks, long offset, long length, int chunkSize)
{
	import std.algorithm : sort;
	import std.conv : to;

	auto span = gridfsChunkSpan(offset, length, chunkSize);

	auto ordered = chunks.dup;
	ordered.sort!((a, b) => a["n"].get!int < b["n"].get!int);

	ubyte[] data;
	foreach (i, chunk; ordered)
	{
		enforce(chunk["n"].get!int == span.first + cast(int) i,
			"GridFS chunk " ~ (span.first + cast(int) i).to!string ~ " is missing");
		data ~= chunk["data"].get!BsonBinData.rawData;
	}

	long start = offset - long(span.first) * chunkSize;
	enforce(cast(long) data.length >= start + length,
		"GridFS range read ends past the stored chunk data");

	return data[cast(size_t) start .. cast(size_t)(start + length)];
}

/// a mid-file range crossing chunk boundaries returns exactly the requested bytes
unittest
{
	auto filesId = BsonObjectID.generate();
	ubyte[] data;
	foreach (i; 0 .. 25)
		data ~= cast(ubyte) i;

	auto chunks = gridfsChunkDocuments(filesId, data, 10);

	assert(gridfsAssembleRange(chunks[0 .. 2], 5, 10, 10) == data[5 .. 15]);
	assert(gridfsAssembleRange(chunks[2 .. 3], 20, 5, 10) == data[20 .. 25]);
	assert(gridfsAssembleRange(chunks, 0, 25, 10) == data);
}

/// chunks supplied out of order still reconstruct the requested range
unittest
{
	import std.algorithm : reverse;

	auto filesId = BsonObjectID.generate();
	ubyte[] data = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];

	auto chunks = gridfsChunkDocuments(filesId, data, 3);
	chunks.reverse;

	assert(gridfsAssembleRange(chunks, 2, 6, 3) == data[2 .. 8]);
}

/// a missing chunk inside the span is rejected
unittest
{
	import std.exception : assertThrown;
	import std.algorithm.mutation : remove;

	auto filesId = BsonObjectID.generate();
	ubyte[] data = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];

	auto chunks = gridfsChunkDocuments(filesId, data, 3);
	chunks = chunks.remove(1);

	assertThrown(gridfsAssembleRange(chunks, 0, 10, 3));
}

/// a range reaching past the stored bytes is rejected instead of silently truncated
unittest
{
	import std.exception : assertThrown;

	auto filesId = BsonObjectID.generate();
	ubyte[] data = [0, 1, 2, 3, 4];

	auto chunks = gridfsChunkDocuments(filesId, data, 3);

	assertThrown(gridfsAssembleRange(chunks, 3, 5, 3));
}

import vibe.db.mongodriver.database : MongoDatabase;
import vibe.db.mongodriver.collection : MongoCollection;
import vibe.db.mongodriver.impl.index : IndexModel;

/// The unique `{files_id: 1, n: 1}` index the GridFS spec requires on the chunks collection.
IndexModel gridfsChunksIndex() @safe
{
	IndexModel m;
	m.add("files_id", 1).add("n", 1);
	m.options.unique = true;
	return m;
}

/// The `{filename: 1, uploadDate: 1}` index the GridFS spec requires on the files collection.
IndexModel gridfsFilesIndex() @safe
{
	IndexModel m;
	m.add("filename", 1).add("uploadDate", 1);
	return m;
}

/// the GridFS chunks index is a unique compound index on (files_id, n) in that order
unittest
{
	auto idx = gridfsChunksIndex();

	string[] keys;
	foreach (string key, value; idx.keys.byKeyValue)
		keys ~= key;
	assert(keys == ["files_id", "n"], "the chunks index key order is files_id then n");
	assert(!idx.options.unique.isNull && idx.options.unique.get, "the chunks index is unique");
}

/// the GridFS files index is a compound index on (filename, uploadDate) in that order
unittest
{
	auto idx = gridfsFilesIndex();

	string[] keys;
	foreach (string key, value; idx.keys.byKeyValue)
		keys ~= key;
	assert(keys == ["filename", "uploadDate"], "the files index key order is filename then uploadDate");
}

/// Node-driver-style GridFS bucket. Stores and reads files split across <bucket>.files and <bucket>.chunks.
struct GridFSBucket
{
	private GridFSBucketOptions m_options;
	private MongoCollection m_files;
	private MongoCollection m_chunks;

	this(MongoDatabase db, GridFSBucketOptions options = GridFSBucketOptions.init)
	{
		m_options = options;
		m_files = db[filesCollectionName(options)];
		m_chunks = db[chunksCollectionName(options)];
	}

	/// Creates the GridFS-required indexes before the first write, but only when the files
	/// collection is empty — so an established bucket is not re-indexed on every upload.
	private void ensureIndexes()
	{
		if (!m_files.findOne(Bson.emptyObject).isNull)
			return;
		m_chunks.createIndex(gridfsChunksIndex());
		m_files.createIndex(gridfsFilesIndex());
	}

	/// Splits `data` into chunks, stores them, then writes the files metadata doc. Returns the file id.
	BsonObjectID uploadFromBuffer(string filename, scope const(ubyte)[] data)
	{
		ensureIndexes();

		auto filesId = BsonObjectID.generate();
		auto chunks = gridfsChunkDocuments(filesId, data, m_options.chunkSizeBytes);

		// If the files document is never written, drop any chunks already inserted so the
		// bucket is not left with invisible orphans.
		scope (failure)
			m_chunks.deleteMany(["files_id": Bson(filesId)]);

		// An empty file is valid (files document with length 0 and zero chunks); insertMany
		// rejects an empty array, so skip the chunk insert entirely.
		if (chunks.length)
			m_chunks.insertMany(chunks);
		m_files.insertOne(gridfsFilesDocument(filesId, filename, cast(long) data.length, m_options.chunkSizeBytes));
		return filesId;
	}

	/// Loads all chunks for `id` and reassembles the original bytes, validating the total
	/// length against the files document so a missing trailing chunk is not silently dropped.
	ubyte[] downloadToBuffer(BsonObjectID id)
	{
		auto fileDoc = m_files.findOne(["_id": Bson(id)]);
		enforce(!fileDoc.isNull, "GridFS file " ~ id.toString ~ " not found");
		auto chunks = m_chunks.find(["files_id": Bson(id)]).array;
		return gridfsAssembleChunks(chunks, fileDoc["length"].get!long);
	}

	/// Reads the byte range [offset, offset + length) of the file described by `fileDoc`,
	/// fetching only the covering chunks. Callers that read repeatedly should hold on to
	/// the files document to avoid one metadata round trip per read.
	ubyte[] readRange(Bson fileDoc, long offset, long length)
	{
		long fileLength = fileDoc["length"].get!long;
		int chunkSize = fileDoc["chunkSize"].get!int;
		enforce(offset >= 0 && length >= 0 && offset + length <= fileLength,
			"GridFS range is outside the stored file");

		if (length == 0)
			return null;

		auto span = gridfsChunkSpan(offset, length, chunkSize);
		auto query = Bson([
			"files_id": fileDoc["_id"],
			"n": Bson(["$gte": Bson(span.first), "$lte": Bson(span.last)])
		]);
		auto chunks = m_chunks.find(query).sort(["n": 1]).array;
		return gridfsAssembleRange(chunks, offset, length, chunkSize);
	}

	/// Reads a byte range by file id, fetching the files document first.
	ubyte[] readRange(BsonObjectID id, long offset, long length)
	{
		auto fileDoc = m_files.findOne(["_id": Bson(id)]);
		enforce(!fileDoc.isNull, "GridFS file " ~ id.toString ~ " not found");
		return readRange(fileDoc, offset, length);
	}

	/// Finds the newest files document with the given filename; a null Bson when absent.
	Bson findFileByName(string filename)
	{
		foreach (doc; m_files.find(["filename": Bson(filename)]).sort(["uploadDate": -1]).limit(1))
			return doc;
		return Bson(null);
	}

	/// Deletes the files document first (making the file invisible), then its chunks,
	/// so a failure between the two cannot leave a visible file with missing data.
	void deleteFile(BsonObjectID id)
	{
		m_files.deleteOne(["_id": Bson(id)]);
		m_chunks.deleteMany(["files_id": Bson(id)]);
	}

	/// Opens a streaming upload for callers that cannot hold the whole file in memory.
	/// Feed bytes with put(), then call finish() for the file id — or abort() to discard.
	GridFSUploadStream openUploadStream(string filename)
	{
		ensureIndexes();
		return GridFSUploadStream(m_files, m_chunks, m_options, filename);
	}

	/// like openUploadStream, but the files document is written up front and flagged, so
	/// findPendingFile and resumeUploadStream can continue it after a crash
	GridFSUploadStream openResumableUploadStream(string filename)
	{
		ensureIndexes();

		auto filesId = BsonObjectID.generate();
		m_files.insertOne(gridfsPendingFilesDocument(filesId, filename, m_options.chunkSizeBytes));

		return GridFSUploadStream(m_files, m_chunks, m_options, filename, filesId, 0, 0);
	}

	/// the newest unfinished files document with this filename; a null Bson when there is none
	Bson findPendingFile(string filename)
	{
		auto query = Bson([
			"filename": Bson(filename),
			gridfsIncompleteField: Bson(true)
		]);

		foreach (doc; m_files.find(query).sort(["uploadDate": -1]).limit(1))
			return doc;
		return Bson(null);
	}

	/// continues `fileDoc`, appending after the chunks already stored
	GridFSUploadStream resumeUploadStream(Bson fileDoc)
	{
		enforce(fileDoc[gridfsIncompleteField].opt!bool(false),
			"GridFS resume needs a files document flagged " ~ gridfsIncompleteField);

		auto filesId = fileDoc["_id"].get!BsonObjectID;
		auto chunkSize = fileDoc["chunkSize"].get!int;
		auto stored = cast(int) m_chunks.countDocuments(["files_id": Bson(filesId)]);

		// only finish() writes a short chunk, so one here means the last run died inside
		// finish() and resuming after it would leave a hole
		if (stored > 0)
		{
			auto last = m_chunks.findOne(["files_id": Bson(filesId), "n": Bson(stored - 1)]);
			if (last.isNull || last["data"].get!BsonBinData.rawData.length != chunkSize)
			{
				m_chunks.deleteOne(["files_id": Bson(filesId), "n": Bson(stored - 1)]);
				stored--;
			}
		}

		return GridFSUploadStream(m_files, m_chunks, m_options, fileDoc["filename"].get!string,
			filesId, stored, long(stored) * chunkSize);
	}

	/// the bytes of the stored chunks in [firstChunk, lastChunk], in order
	ubyte[] readChunks(BsonObjectID filesId, int firstChunk, int lastChunk)
	{
		import std.conv : to;

		if (lastChunk < firstChunk)
			return null;

		auto query = Bson([
			"files_id": Bson(filesId),
			"n": Bson(["$gte": Bson(firstChunk), "$lte": Bson(lastChunk)])
		]);

		ubyte[] data;
		auto expected = firstChunk;
		foreach (chunk; m_chunks.find(query).sort(["n": 1]))
		{
			enforce(chunk["n"].get!int == expected,
				"GridFS chunk " ~ expected.to!string ~ " is missing");
			data ~= chunk["data"].get!BsonBinData.rawData;
			expected++;
		}

		enforce(expected == lastChunk + 1,
			"GridFS chunk " ~ expected.to!string ~ " is missing");

		return data;
	}
}

/// Output-range style streaming upload: put() buffers bytes into chunk documents and
/// batches the inserts; finish() writes the files document that makes the file visible.
struct GridFSUploadStream
{
	private MongoCollection m_files;
	private MongoCollection m_chunks;
	private GridFSBucketOptions m_options;
	private string m_filename;
	private BsonObjectID m_filesId;
	private ubyte[] m_buffer;
	private Bson[] m_pending;
	private int m_nextChunk;
	private long m_totalLength;
	private bool m_closed;
	private bool m_resumable;

	/// chunk documents buffered per insertMany; ~12.5 MiB of data at the default chunk size
	enum int insertBatchSize = 50;

	this(MongoCollection files, MongoCollection chunks, GridFSBucketOptions options, string filename)
	{
		m_files = files;
		m_chunks = chunks;
		m_options = options;
		m_filename = filename;
		m_filesId = BsonObjectID.generate();
	}

	/// continues an existing files document; finish() updates it instead of inserting
	this(MongoCollection files, MongoCollection chunks, GridFSBucketOptions options,
		string filename, BsonObjectID filesId, int nextChunk, long stored)
	{
		m_files = files;
		m_chunks = chunks;
		m_options = options;
		m_filename = filename;
		m_filesId = filesId;
		m_nextChunk = nextChunk;
		m_totalLength = stored;
		m_resumable = true;
	}

	/// the id the files document will be stored under once finish() runs
	BsonObjectID filesId() const
	{
		return m_filesId;
	}

	/// bytes handed to put() so far, including any carried over by a resume
	long storedBytes() const
	{
		return m_totalLength;
	}

	/// buffers bytes, inserting chunk documents as they fill
	void put(scope const(ubyte)[] data)
	{
		enforce(!m_closed, "GridFS upload stream is already closed");

		m_buffer ~= data;
		m_totalLength += data.length;

		while (m_buffer.length >= m_options.chunkSizeBytes)
		{
			enqueueChunk(m_buffer[0 .. m_options.chunkSizeBytes]);
			m_buffer = m_buffer[m_options.chunkSizeBytes .. $];
		}
	}

	private void enqueueChunk(scope const(ubyte)[] slice)
	{
		m_pending ~= gridfsChunkDocument(m_filesId, m_nextChunk, slice);
		m_nextChunk++;

		if (m_pending.length >= insertBatchSize)
			flushPending();
	}

	private void flushPending()
	{
		if (!m_pending.length)
			return;

		m_chunks.insertMany(m_pending);
		m_pending = null;
	}

	/// flushes the trailing partial chunk and writes the files document; returns the file id
	BsonObjectID finish()
	{
		enforce(!m_closed, "GridFS upload stream is already closed");

		if (m_buffer.length)
			enqueueChunk(m_buffer);
		m_buffer = null;
		flushPending();

		if (m_resumable)
		{
			// clearing the flag is what makes the file complete
			m_files.updateOne(["_id": Bson(m_filesId)], Bson([
				"$set": Bson(["length": Bson(m_totalLength)]),
				"$unset": Bson([gridfsIncompleteField: Bson("")])
			]));
		}
		else
			m_files.insertOne(gridfsFilesDocument(m_filesId, m_filename, m_totalLength, m_options.chunkSizeBytes));

		m_closed = true;
		return m_filesId;
	}

	/// the deliberate give-up: drops the chunks and any pending files document. A process
	/// that simply dies runs none of this, which is what leaves the upload resumable.
	void abort()
	{
		m_chunks.deleteMany(["files_id": Bson(m_filesId)]);

		if (m_resumable)
			m_files.deleteOne(["_id": Bson(m_filesId)]);

		m_buffer = null;
		m_pending = null;
		m_closed = true;
	}
}
