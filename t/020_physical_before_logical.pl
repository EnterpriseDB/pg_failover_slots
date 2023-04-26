
use strict;
use warnings;
use File::Path qw(rmtree);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $offset = 0;

# Test set-up
my $node_primary = PostgreSQL::Test::Cluster->new('test');
$node_primary->init(allows_streaming => 'logical');
$node_primary->append_conf('postgresql.conf', "shared_preload_libraries = pg_failover_slots");
# Setup physical before logical slot
$node_primary->append_conf('postgresql.conf', "pg_failover_slots.standby_slot_names = 'standby_1'");

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

# Create table.
$node_primary->safe_psql('postgres', "CREATE TABLE test_repl_stat(col1 int)");

# Create subscriber node
my $node_subscriber = PostgreSQL::Test::Cluster->new('subscriber');
$node_subscriber->init(allows_streaming => 'logical');
$node_subscriber->start;

$node_subscriber->safe_psql('postgres', "CREATE TABLE test_repl_stat(col1 int)");

my $node_primary_connstr = $node_primary->connstr . ' dbname=postgres application_name=tap_sub';
$node_primary->safe_psql('postgres', "CREATE PUBLICATION tap_pub FOR ALL TABLES");
$node_subscriber->safe_psql('postgres',
        "CREATE SUBSCRIPTION tap_sub CONNECTION '$node_primary_connstr' PUBLICATION tap_pub"
);
$node_primary->wait_for_catchup('tap_sub');

# Create replication slots.
$node_primary->safe_psql(
	'postgres', qq[
	SELECT pg_create_logical_replication_slot('regression_slot1', 'test_decoding');
]);

# Insert some data.
$node_primary->safe_psql('postgres',
	"INSERT INTO test_repl_stat values(generate_series(1, 5));");

# Fetching using pg_logical_slot_get_changes should work fine
$node_primary->safe_psql(
	'postgres', qq[
	SELECT data FROM pg_logical_slot_get_changes('regression_slot1', NULL,
	NULL, 'include-xids', '0', 'skip-empty-xacts', '1');
]);

# Replication via pub/sub should time out though
$offset = $node_primary->wait_for_log(
        qr/terminating walsender process due to pg_failover_slots.standby_slot_names replication timeout/,
        0);

# And subscriber should have nothing
is($node_subscriber->safe_psql('postgres', "SELECT * FROM test_repl_stat"), "");

# Start standby
$node_standby->start;

# Wait for it to replicate
my $primary_lsn = $node_primary->lsn('write');
$node_primary->wait_for_catchup($node_standby, 'replay', $primary_lsn);

# Make sure subscriber replicates
$node_subscriber->poll_query_until('postgres', "SELECT count(*) > 4 FROM test_repl_stat");

# Stop standby again
$node_standby->stop;

# Insert more data
$node_primary->safe_psql('postgres',
	"INSERT INTO test_repl_stat values(generate_series(10, 15));");

# Pub/Sub replication should timeout again
$offset = $node_primary->wait_for_log(
        qr/terminating walsender process due to pg_failover_slots.standby_slot_names replication timeout/,
        $offset);

# shutdown
$node_primary->stop;
$node_subscriber->stop;

done_testing();
