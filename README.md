# foslots

PG Failover Slots is for anyone with Logical Replication Slots on Postgres databases that are also part of a Physical Streaming Replication architecture.

Since logical replication slots are only maintained on the primary node, downstream subscribers don't receive any new changes from a newly promoted primary until the slot is created, which is unsafe because the information that includes which data a subscriber has confirmed receiving and which log data still needs to be retained for the subscriber will have been lost, resulting in an unknown gap in data changes. PG Failover Slots makes logical replication slots usable across a physical failover using the following features:

- Copies any missing replication slots from the primary to the standby
- Removes any slots from the standby that aren't found on the primary
- Periodically synchronizes the position of slots on the standby based on the primary
- Ensures that selected standbys receive data before any of the logical slot walsenders can send data to consumers

PostgreSQL 15 or higher is required.

## How to check the standby is ready

The slots are not synchronized to the standby immediately, because of
consistency reasons. The standby can be too behind logical slots, or too ahead
of logical slots on primary when the pg_failover_slots module is activated,
so the module does verification and only synchronizes slots when it's
actually safe.

This, however brings a need to verify that the slots are synchronized and
that the standby is actually ready to be a failover target with consistent
logical decoding for all slots. This only needs to be done initially, once
the slots are synchronized the first time, they will always be consistent as
long as the module is active in the cluster.

The check for whether slots are fully synchronized with primary is relatively
simple. The slots just need to be present in `pg_replication_slots` view on
standby and have `active` state `false`. An `active` state `true` means the
slots is currently being initialized.

For example consider the following psql session:

```psql
# SELECT slot_name, active FROM pg_replication_slots WHERE slot_type = 'logical';
    slot_name    | active
-----------------+--------
regression_slot1 | f
regression_slot2 | f
regression_slot3 | t
```

This means that slots `regression_slot1` and `regression_slot2` are synchronized
from primary to standby and `regression_slot3` is still being synchronized. If
failover happens at this stage, the `regression_slot3` will be lost.

Now let's wait a little and query again:

```psql
# SELECT slot_name, active FROM pg_replication_slots WHERE slot_type = 'logical';
    slot_name    | active
-----------------+--------
regression_slot1 | f
regression_slot2 | f
regression_slot3 | f
```

Now all the the three slots are synchronized and the standby can be used
for failover without losing logical decoding state for any of them.

## Prerequisite settings

The module throws hard errors if the following settings are not adjusted:

- `hot_standby_feedback` should be `on`
- `primary_slot_name` should be non-empty

These are necessary to connect to the primary so it can send the xmin and
catalog_xmin separately over hot_standby_feedback.

## Configuration options

The module itself must be added to `shared_preload_libraries` on both the
primary instance as well as any standby that is used for high availability
(failover or switchover) purposes.

The behavior of pg_failover_slots is configurable using these configuration
options (set in `postgresql.conf`).

### pg_failover_slots.synchronize_slot_names

This standby option allows setting which logical slots should be synchronized
to this physical standby. It's a comma-separated list of slot filters.

A slot filter is defined as  `key:value` pair (separated by colon) where `key`
can be one of:

 - `name` - specifies to match exact slot name
 - `name_like` - specifies to match slot name against SQL `LIKE` expression
 - `plugin` - specifies to match slot plugin name against the value

The `key` can be omitted and will default to `name` in that case.

For example, `'my_slot_name,plugin:test_decoding'` will
synchronize the slot named "my_slot_name" and any slots that use the test_decoding plugin.

If this is set to an empty string, no slots will be synchronized to this physical
standby.

The default value is `'name_like:%'`, which means all logical replication slots
will be synchronized.


### pg_failover_slots.drop_extra_slots

This standby option controls what happens to extra slots on the standby that are
not found on the primary using the `pg_failover_slots.synchronize_slot_names` filter.
If it's set to true (which is the default), they will be dropped, otherwise
they will be kept.

### pg_failover_slots.primary_dsn

A standby option for specifying the connection string to use to connect to the
primary when fetching slot information.

If empty (default), then use same connection string as `primary_conninfo`.

Note that `primary_conninfo` cannot be used if there is a `password` field in
the connection string because it gets obfuscated by PostgreSQL and
pg_failover_slots can't actually see the password. In this case,
`pg_failover_slots.primary_dsn` must be configured.

### pg_failover_slots.standby_slot_names

This option is typically used in failover configurations to ensure that the
failover-candidate streaming physical replica(s) have received and flushed
all changes before they ever become visible to any subscribers. That guarantees
that a commit cannot vanish on failover to a standby for the consumer of a logical
slot.

Replication slots whose names are listed in the comma-separated
`pg_failover_slots.standby_slot_names` list are treated specially by the
walsender on the primary.

Logical replication walsenders will ensure that all local changes are sent and
flushed to the replication slots in `pg_failover_slots.standby_slot_names`
before the walsender sends those changes for the logical replication slots.
Effectively, it provides a synchronous replication barrier between the named
list of slots and all the consumers of logically decoded streams from walsender.

Any replication slot may be listed in `pg_failover_slots.standby_slot_names`;
both logical and physical slots work, but it's generally used for physical
slots.

Without this safeguard, two anomalies are possible where a commit can be
received by a subscriber and then vanish from the provider on failover because
the failover candidate hadn't received it yet:

* For 1+ subscribers, the subscriber may have applied the change but the new
  provider may execute new transactions that conflict with the received change,
  as it never happened as far as the provider is concerned;

and/or

* For 2+ subscribers, at the time of failover, not all subscribers have applied
  the change. The subscribers now have inconsistent and irreconcilable states
  because the subscribers that didn't receive the commit have no way to get it
  now.

Setting `pg_failover_slots.standby_slot_names` will (by design) cause subscribers to
lag behind the provider if the provider's failover-candidate replica(s) are not
keeping up. Monitoring is thus essential.

### pg_failover_slots.standby_slots_min_confirmed

Controls how many of the `pg_failover_slots.standby_slot_names` have to
confirm before we send data through the logical replication
slots. Setting -1 (the default) means to wait for all entries in
`pg_failover_slots.standby_slot_names`.

