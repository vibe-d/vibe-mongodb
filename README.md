# vibe-mongodb

A MongoDB database client for D, built on [vibe.d](https://github.com/vibe-d/vibe.d). Speaks the
modern wire protocol and supports MongoDB servers up to 8.0.

This is the driver behind `vibe-d:mongodb`. It used to live inside the vibe.d repository and now has
its own, so it can be released and tested against the full range of MongoDB servers independently.
The `vibe.db.mongo` module names and the API are unchanged.

```json
"dependencies": {
	"vibe-mongodb": "~>2.0.0"
}
```

Depending on `vibe-d:mongodb` keeps working too: that subpackage forwards to this one.

## Features

**Topology and connections**

* Server Discovery and Monitoring (SDAM) with per server health monitors and cooldown handling
* Replica sets, including primary step down detection, arbiter awareness and stale primary demotion
* Sharded clusters and load balanced mode
* Read preferences with tag sets and `maxStalenessSeconds`
* `mongodb+srv` DNS seedlist resolution
* Connection quarantine and recovery from dead connections
* Wire protocol compression (`OP_COMPRESSED`), with credential and handshake commands exempted

**Operations**

* MongoDB 8 server level `bulkWrite`, including upserted ids, unacknowledged writes and `errInfo`
  propagation
* Retryable writes with topology refresh on step down
* Read concern and write concern throughout
* Change streams at collection, database and client level
* GridFS
* Index management

**Sessions and consistency**

* Server sessions with pooling
* Multi document transactions, with `withTransactionRetry` preserving the original error
* Causal consistency through cluster time gossiping
* Stable API (`apiVersion`) and session timeout handling

**Security**

* SCRAM-SHA-1 and SCRAM-SHA-256 authentication
* X.509 authentication
* TLS, with optional certificate verification
* Client side field level encryption, with a key vault interface

## Server compatibility

Every release is tested against each of these in CI.

| MongoDB server | Status |
| --- | --- |
| 3.6 | Tested |
| 4.0 | Tested |
| 4.2 | Tested |
| 4.4 | Tested |
| 5.0 | Tested |
| 6.0 | Tested |
| 7.0 | Tested |
| 8.0 | Tested |

Features that the server does not offer are detected at runtime rather than assumed. Transactions and
change streams need a replica set or a sharded cluster, and server level `bulkWrite` needs 8.0.

## Usage

```d
import vibe.db.mongo.mongo;

auto client = connectMongoDB("127.0.0.1");
auto users = client.getCollection("myapp.users");

users.insertOne(["name": "Peter", "city": "Bucharest"]);

auto peter = users.findOne(["name": "Peter"]);
if (!peter.isNull)
	logInfo("found %s", peter["city"].get!string);
```

Connection strings are supported in full:

```d
auto client = connectMongoDB("mongodb://user:password@host1,host2/?replicaSet=rs0&readPreference=secondaryPreferred");
auto srv    = connectMongoDB("mongodb+srv://user:password@cluster.example.com/");
```

`MongoClient` runs background monitor tasks, so it is meant to be created once and shared between
fibers in a thread. When you need a client with a bounded lifetime, `scopedMongoDB` returns a handle
that stops those monitors when it leaves scope:

```d
auto client = scopedMongoDB("127.0.0.1");
auto users = client.getCollection("myapp.users");
```

Transactions need a replica set member or a mongos:

```d
auto session = client.startSession();
session.startTransaction();

orders.insertOne(Bson(["item": Bson("cigar"), "qty": Bson(12)]),
	InsertOneOptions.init, &session);

session.commitTransaction();
session.endSession();
```

Every operation that can take part in a transaction accepts a `MongoClientSession*` as its last
argument.

## Migrating from `vibe-d:mongodb`

No code changes are needed. Either keep depending on `vibe-d:mongodb`, or replace it with
`vibe-mongodb` in your `dub.json`. Module names are the same, so imports stay as they are.

### Migrating from `vibe-mongodriver`

`vibe-mongodriver` was the name of this package before it moved into the vibe-d organization. Its
modules lived under `vibe.db.mongodriver`. Switch the dependency to `vibe-mongodb` and rename the
imports:

```sh
find . -name '*.d' -exec sed -i -E 's/vibe\.db\.mongodriver\b/vibe.db.mongo/g' {} +
```

`InsertOneResult.insertedId` and `UpdateResult.upsertedIds` hold `BsonObjectID` values again, as
in `vibe-d:mongodb`. Code that relied on them carrying ids of any BSON type should read
`insertedIdValue` and `upsertedIdValues` instead.

## Running the tests

Unit tests need nothing but a compiler:

```sh
dub test
```

The integration suite lives in `tests/` as 19 independent dub projects. It needs `mongod`,
`mongodump` from the MongoDB database tools, and either the legacy `mongo` shell (servers up to 5.0)
or `mongosh` (6.0 and later) on `PATH`:

```sh
./run-ci.sh                    # unit tests, then every integration project
PARTS=unittests ./run-ci.sh    # unit tests only
PARTS=mongo ./run-ci.sh        # integration tests only
```

Most projects have their server started and stopped for them. The ones needing unusual setup, such as
replica sets, authentication modes or a load balancer, bring their own `run.sh`. Tests that require a
capability the running server does not have will skip themselves rather than fail.

## Tracking upstream

`import-upstream.sh` applies a commit from a vibe.d checkout that touches the old `mongodb/`
subpackage to this repository, translating paths as it goes:

```sh
./import-upstream.sh <upstream-sha> ~/src/vibe.d
```

## History and credits

The MongoDB driver was originally written as part of [vibe.d](https://github.com/vibe-d/vibe.d) by
Sönke Ludwig and contributors. This repository preserves that history: the commits here are the real
ones, filtered out of the vibe.d tree with `git-filter-repo`, not a flattened import.

`docs/history-map.txt` maps every commit in this repository back to its original SHA in
`gedaiu/vibe.d`, so provenance stays traceable. Those SHAs predate the move back to the
`vibe.db.mongo` module names.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
