#!/usr/bin/env perl


use RADIUS::XMLParser;

my @logs = qw(radius.log);
my @labels = qw(
Event-Timestamp
User-Name
File
);

my $radius = RADIUS::XMLParser->new(
	DEBUG=>1, 
	DAYSFORORPHAN=>1, 
	AUTOPURGE=>0, 
	ALLEVENTS=>1, 
	XMLENCODING=>"us-ascii", 
	OUTPUTDIR=>'/tmp/radius', 
	LABELS=>\@labels
	) or die "Cannot create parser: $!";
	
my $result = $radius->group(\@logs);



