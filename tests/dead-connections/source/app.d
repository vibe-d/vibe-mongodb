import vibe.db.mongo.mongo;
import vibe.db.mongo.client;
import vibe.db.mongo.settings;
import vibe.core.core;
import vibe.core.log;
import vibe.data.bson;
import core.time;
import std.conv;
import std.exception;

/// The sockets this process holds open. An evicted connection that is never
/// closed stays in this list for the life of the process.
size_t openSockets()
{
	import std.algorithm : count, startsWith;
	import std.file : dirEntries, readLink, SpanMode;

	return dirEntries("/proc/self/fd", SpanMode.shallow)
		.count!((entry) {
			try return readLink(entry.name).startsWith("socket:");
			catch (Exception) return false;
		});
}

/// Inserts one document through each client. A client's pool holds exactly one
/// connection after a serial insert, so `clients.length` clients hold exactly that
/// many pooled sockets, however the scheduler interleaves them.
void insertThroughEach(MongoClient[] clients, string value)
{
	foreach (index, client; clients)
	{
		auto coll = client.getCollection("deadconn_test.items");
		coll.insertOne(Bson(["_id": Bson(BsonObjectID.generate), "client": Bson(cast(long) index), "value": Bson(value)]));
	}
}

enum clientCount = 6;

int main(string[] args)
{
	setLogLevel(LogLevel.diagnostic);

	if (args.length < 2)
	{
		logError("Usage: %s <port>", args[0]);
		return 1;
	}

	runTask({ sleepUninterruptible(30.seconds); assert(false, "Timeout exceeded"); });

	ushort port = args[1].to!ushort;

	auto settings = new MongoClientSettings;
	settings.hosts = [MongoHost("127.0.0.1", port)];
	settings.connectTimeoutMS = 5_000;
	settings.socketTimeoutMS = 2_000;
	settings.appName = "DeadConnTest";

	logInfo("Phase 1: Create %s clients with one pooled connection each", clientCount);

	MongoClient[] clients;
	try
	{
		foreach (_; 0 .. clientCount)
			clients ~= connectMongoDB(settings);
		insertThroughEach(clients, "before-restart");
	}
	catch (Exception e)
	{
		logError("Failed to connect: %s", e.msg);
		return 1;
	}

	const socketsBeforeRestart = openSockets();

	logInfo("Phase 1 passed: %s clients inserted, %s sockets open", clientCount, socketsBeforeRestart);

	// Signal that we're ready for the server to be killed
	import std.stdio : File;
	auto f = File("ready", "w");
	f.write("ready");
	f.close();

	logInfo("Phase 2: Waiting for server restart...");

	// Wait for the "restarted" signal file
	foreach (_; 0 .. 60)
	{
		try
		{
			auto rf = File("restarted", "r");
			rf.close();
			break;
		}
		catch (Exception)
		{
			sleepUninterruptible(500.msecs);
		}
	}

	logInfo("Phase 3: Attempting operations after server restart");

	auto coll = clients[0].getCollection("deadconn_test.items");

	// Every pooled connection is dead now. Each one has to be closed when it is
	// evicted, or its socket stays open until the process ends.
	bool success = false;
	try
	{
		auto objID = BsonObjectID.generate;
		coll.insertOne(Bson(["_id": Bson(objID), "value": Bson("after-restart")]));

		auto doc = coll.findOne(["_id": objID]);
		enforce(!doc.isNull, "Inserted document not found after restart");
		enforce(doc["value"].get!string == "after-restart", "Document content mismatch");

		insertThroughEach(clients, "after-restart");

		const socketsAfterRestart = openSockets();
		logInfo("%s sockets open before the restart, %s after", socketsBeforeRestart, socketsAfterRestart);
		enforce(socketsAfterRestart <= socketsBeforeRestart,
			"Evicted connections were not closed: " ~ socketsBeforeRestart.to!string
			~ " sockets before the restart, " ~ socketsAfterRestart.to!string ~ " after");

		success = true;
	}
	catch (Exception e)
	{
		logError("Post-restart operation failed: %s", e.msg);
	}

	// Cleanup
	try { coll.drop(); } catch (Exception) {}

	if (success)
	{
		logInfo("All dead-connection eviction tests passed");
		return 0;
	}

	logError("Dead connection test failed");
	return 1;
}
