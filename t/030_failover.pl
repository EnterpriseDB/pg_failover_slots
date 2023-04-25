
use strict;
use warnings;
use File::Path qw(rmtree);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Test set-up
my $node_primary = PostgreSQL::Test::Cluster->new('test');
$node_primary->init(allows_streaming => 'logical');
$node_primary->append_conf('postgresql.conf', 'shared_preload_libraries = pg_failover_slots');
$node_primary->start;
is( $node_primary->psql(
                'postgres',
                qq[SELECT pg_create_physical_replication_slot('standby_1');]),
        0,
        'physical slot created on primary');
my $backup_name = 'my_backup';

# Take backup
$node_primary->backup($backup_name);

# Create streaming standby linking to primary
my $node_standby = PostgreSQL::Test::Cluster->new('standby_1');
$node_standby->init_from_backup($node_primary, $backup_name,
        has_streaming => 1);
$node_standby->append_conf('postgresql.conf', 'hot_standby_feedback = on');

my $pg_version = `pg_config --version | awk '{print \$2}'`;
if ($pg_version >= 12) {
	$node_standby->append_conf('postgresql.conf', 'primary_slot_name = standby_1');
}
else {
	$node_standby->append_conf('recovery.conf', 'primary_slot_name = standby_1');
}
$node_standby->start;

# Wait for the sync worker to start
$node_standby->poll_query_until('postgres', "SELECT count(*) > 0 FROM pg_stat_activity where application_name LIKE 'pg_failover_slots%'");

# Create table.
$node_primary->safe_psql('postgres', "CREATE TABLE test_repl_stat(col1 serial)");

	# Create replication slots.
$node_primary->safe_psql(
	'postgres', qq[
	SELECT pg_create_logical_replication_slot('regression_slot1', 'test_decoding');
	SELECT pg_create_logical_replication_slot('regression_slot2', 'test_decoding');
	SELECT pg_create_logical_replication_slot('regression_slot3', 'test_decoding');
	SELECT pg_create_logical_replication_slot('regression_slot4', 'test_decoding');
]);

# Simulate some small load to move things forward and wait for slots to be
# synced downstream.
while (1) {
	$node_primary->safe_psql(
		'postgres', qq[
		SELECT data FROM pg_logical_slot_get_changes('regression_slot1', NULL,
			NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
		SELECT data FROM pg_logical_slot_get_changes('regression_slot2', NULL,
			NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
		SELECT data FROM pg_logical_slot_get_changes('regression_slot3', NULL,
			NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
		SELECT data FROM pg_logical_slot_get_changes('regression_slot4', NULL,
			NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
	]);

	$node_primary->safe_psql('postgres', "INSERT INTO test_repl_stat DEFAULT VALUES;");

	last if ($node_standby->safe_psql('postgres',"SELECT count(*) > 3 FROM pg_replication_slots WHERE NOT active") eq "t");

	sleep(1);
}

# Now that slots moves they should be all synced
is($node_standby->safe_psql('postgres', "SELECT slot_name FROM pg_replication_slots ORDER BY slot_name"), q[regression_slot1
regression_slot2
regression_slot3
regression_slot4], 'all slots synced');

# Wait for replication to catch up
my $primary_lsn = $node_primary->lsn('write');
$node_primary->wait_for_catchup($node_standby, 'replay', $primary_lsn);

# failover to standby
$node_primary->stop;
$node_standby->promote;

# Check that slots are on promoted standby
is($node_standby->safe_psql('postgres', "SELECT slot_name FROM pg_replication_slots ORDER BY slot_name"), q[regression_slot1
regression_slot2
regression_slot3
regression_slot4], 'slots are on promoted standby');

# Write on promoted standby
$node_standby->safe_psql('postgres', "INSERT INTO test_repl_stat DEFAULT VALUES;");

# Check that slots are consumable on promoted stanby
$node_standby->safe_psql(
	'postgres', qq[
	SELECT data FROM pg_logical_slot_get_changes('regression_slot1', NULL,
		NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
	SELECT data FROM pg_logical_slot_get_changes('regression_slot2', NULL,
		NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
	SELECT data FROM pg_logical_slot_get_changes('regression_slot3', NULL,
		NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
	SELECT data FROM pg_logical_slot_get_changes('regression_slot4', NULL,
		NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
]);

# shutdown
$node_standby->stop;

done_testing();
