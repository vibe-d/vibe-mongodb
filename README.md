# vibe-mongodriver

A MongoDB database client for D. Speaks the modern wire protocol and supports MongoDB servers up to
8.0.

It is a maintained continuation of the driver that ships inside vibe.d as `vibe-d:mongodb`, with the
API kept compatible and a large amount of work added on top: server discovery and monitoring,
transactions, change streams, GridFS, field level encryption, and MongoDB 8 bulk writes.

```json
"dependencies": {
	"vibe-mongodriver": "~>1.0.0"
}
```

## Why this exists

This library started as MongoDB work inside a fork of vibe.d. It became its own package for two
reasons.

The first is that contributing to upstream vibe.d is hard. The work here spans 90 commits across what
amounts to a driver rewrite, and getting changes of that size reviewed and merged upstream has not
been practical. Rather than let the work sit in a private fork forever, it is published here so
anyone can use it.

The second is that the gap is worth closing. Not supporting modern MongoDB versions and features is
one of the bigger reasons people pass on vibe.d for a new project. If you need transactions, change
streams, or a driver that talks to a MongoDB 8 server properly, the answer should not have to be "use
another language". This package is that answer.

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
import vibe.db.mongodriver.mongo;

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

The API is unchanged. Only the module names differ, so migration is one command:

```sh
find . -name '*.d' -exec sed -i -E 's/vibe\.db\.mongo\b/vibe.db.mongodriver/g' {} +
```

Because only the module names differ, **both packages can be linked into the same binary**. Nothing
collides. A large codebase can therefore move one module at a time instead of all at once, and a
library that still imports `vibe.db.mongo` will not stop your application from using this driver
elsewhere.

The rewrite above matches on a word boundary, so running it twice is a no op.

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

`import-upstream.sh` applies a commit from a vibe.d checkout to this repository, translating paths and
module names as it goes:

```sh
./import-upstream.sh <upstream-sha> ~/src/vibe.d
```

## History and credits

The MongoDB driver was originally written as part of [vibe.d](https://github.com/vibe-d/vibe.d) by
Sönke Ludwig and contributors. This repository preserves that history: the commits here are the real
ones, filtered out of the vibe.d tree with `git-filter-repo`, not a flattened import.

`docs/history-map.txt` maps every commit in this repository back to its original SHA in
`gedaiu/vibe.d`, so provenance stays traceable.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
