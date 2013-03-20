use Test::More;
use RADIUS::XMLParser;
use File::Basename;
use Test::Files;

my $test_file        = 'resources/radius.log';
my $test_output_dir  = 'tmp';
my $test_output_file = 'radius.xml';
my @labels;
my %expect;
my %actual;
my $parser;
my $xml;

# Declare labels to write in test XML
@labels = qw(
  File
);

# What to expect in test
%expect = (
	'ERRORS'          => 0,
	'EVENT_INTERIM'   => 130,
	'EVENT_START'     => 46,
	'EVENT_STOP'      => 46,
	'PROCESSED_LINES' => 5659
);

# Initialize parser
$parser = RADIUS::XMLParser->new(
	{
		ORPHANDIR => $test_output_dir,
		ALLEVENTS => 1,
		OUTPUTDIR => $test_output_dir,
		LABELS    => \@labels
	}
);

# Parse test file
$parser->convert($test_file);

# Test that XML has been created
dir_only_contains_ok( $test_output_dir, [qw(tmp radius.xml)],
	"Assert that radius.xml has been created" );
if ( -e "$test_output_dir/radius.xml" ) {
	unlink "$test_output_dir/radius.xml";
}

# Retrieve metadata
my $metadata = $parser->metadata();
%actual = %$metadata;

# Test expected Vs. Actual values
for my $key ( keys %expect ) {
	ok( $actual{$key} == $expect{$key},
		"Assert that returned $key is equal to $expect{$key}" );
}

# End test (declare test run)
done_testing( scalar( keys %expect ) + 1 );
