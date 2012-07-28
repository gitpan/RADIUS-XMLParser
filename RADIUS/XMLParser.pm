package RADIUS::XMLParser;

use strict;
use warnings;

use Storable qw(lock_store lock_retrieve);
use Carp;
use Data::Dumper;
use File::Basename;
use XML::Writer;
use IO::File;

our $VERSION = '1.20';

my %tags = ();
my %event;
my %start;
my %stop;
my %interim;
my $interimUpdate;
my $orphanDir = '/tmp';
my $debug = 0;
my @labels;
my $writer;
my $daysForOrphan = 1;
my $labelref;
my $purgeOrphan = 0;
my $writeAllEvents = 0;
my $xmlencoding = "utf-8";
my $fname;
my $outputDir = '/tmp';
my $startDbm;
my $interimDbm;
my $stopDbm;
my $controlDataStructure = 0;



#--------------------------------------------------
#Construct the parser object

sub new {

	my $this   = shift;
	my $class  = ref($this) || $this;
	my %params = @_;
	$fname = "radius::XMLparser::new()";

	#Load parameters if any
	$debug = $params{DEBUG} if ($params{DEBUG});
	$labelref = $params{LABELS} if $params{LABELS};
	$purgeOrphan = $params{AUTOPURGE} if $params{AUTOPURGE};
	$daysForOrphan = $params{DAYSFORORPHAN} if $params{DAYSFORORPHAN};
	$writeAllEvents = $params{ALLEVENTS} if $params{ALLEVENTS};
	$xmlencoding = $params{XMLENCODING} if $params{XMLENCODING};
	$outputDir = $params{OUTPUTDIR} if $params{OUTPUTDIR};
	$orphanDir = $params{ORPHANDIR} if $params{ORPHANDIR};
	$controlDataStructure = $params{CONTROLDATA} if $params{CONTROLDATA};
	@labels = @$labelref if $labelref;
	
	#Print supplied parameters
	foreach my $key (keys %params){
		print "$fname: CONF: params{$key} = ".$params{$key}."\n" if $debug;
	}

	$startDbm = "$orphanDir/orphan.start";
	$interimDbm = "$orphanDir/orphan.interim";
	$stopDbm = "$orphanDir/orphan.stop";

	#Load previously stored hash if any
	_loadHash();


	my $self   = {};
	#Amen !
	bless $self => $class;

	$self;
}



#--------------------------------------------------
#Open log file and parse each line. Group then all event by session ID

sub group($$) {

	my ($self, $logFileRef) = @_;
	my $totalErrors = 0;
	$fname = "RADIUS::XMLParser::group()";

	#Logs files to analyze can be provided as an array ref
	for my $log (@$logFileRef){

		#Initialize counters
		my $processedLines = 0;
		my $errorLines = 0;

		#Open log file to be parsed
		open (LOG, $log) or croak "Cannot open file; File=$log; $!";
		print "$fname: Will now parse file $log\n" if $debug;

		#Boolean that becomes true (1) when the first blank lines have been skipped.
		my $begining_skipped = 0;

		#Get each line 
		while ( <LOG> ) {

			$processedLines++;

			# Skip the begining of the log file if it only contains blank lines.
			if (/^(\s)*$/ && !$begining_skipped) {
				next;
			} else {
				$begining_skipped = 1;
			}

			# Analyze line
			unless(_analyseRadiusLine( $_, $processedLines, $log )){
				$errorLines ++;
			}
		}

		#Print sum up
		print "$fname: TOTAL ".$processedLines ." line(s) have been processed\n" if $debug;
		print "$fname: TOTAL ".$errorLines ." error(s) found\n" if $debug;
		print "$fname: TOTAL ".scalar(keys %stop)." stop event(s) found\n" if $debug;
		print "$fname: TOTAL ".scalar(keys %start)." start event(s) found\n" if $debug;

		#Control data structure
		if ($controlDataStructure){
			
			
			my $stopControlFile = $stopDbm.".dbm";
			my $startControlFile = $startDbm.".dbm";
			my $interimControlFile = $interimDbm.".dbm";
			
			open (STOP, ">", $stopControlFile) or croak "Cannot open file; File=$stopControlFile; $!";
			print "$fname: Printing out STOP dataStructure to $stopControlFile\n" if $debug;
			print STOP Dumper(%stop);
			close(STOP);
			open (START, ">", $startControlFile) or croak "Cannot open file; File=$startControlFile; $!";
			print "$fname: Printing out START dataStructure to $startControlFile\n" if $debug;
			print START Dumper(%start);
			close(START);
			open (INTERIM, ">", $interimControlFile) or croak "Cannot open file; File=$interimControlFile; $!";
			print "$fname: Printing out INTERIM dataStructure to $interimControlFile\n" if $debug;
			print INTERIM Dumper(%interim);
			close(INTERIM);
			
		}

		#Store file into XML
		print "$fname: Will now convert $log into xml\n" if $debug;
		$self->convert($log);
		
		$fname = "RADIUS::XMLParser::group()";
		#Log has been parsed
		close (LOG);

		print "$fname: All done for file $log\n" if $debug;

		print "$fname: Reinitializing Stop hash table\n";
		%stop = ();
		$totalErrors += $errorLines;

	} #Next log file

	#Print sum up
	print "$fname: All Done for all files!\n" if $debug;
	print "$fname: Orphan Start is now ".scalar(keys %start)." items long\n" if $debug;
	print "$fname: Orphan Interim is now ".scalar(keys %interim)." items long\n" if $debug;

	return $totalErrors;

}


#--------------------------------------------------
#Convert Stop event hash reference to XML

sub convert($$){

	my ($self, $log) = @_;
	$fname = "RADIUS::XMLParser::convert()";

	#Initialize counter
	my $stopevents = 0;
	my $startevents = 0;
	my $interimevents = 0;

	#Create output xml file	
	$log = basename($log);
	my $xml = $log;
	if($log =~ m/\.log/){
		$xml =~ s/\.log/\.xml/g;
	} else {
		$xml = $log .".xml";
	}
	

	#Create a new IO::File
	my $output = IO::File->new(">$outputDir/$xml") or croak "Cannot open file $xml, $!";
	print "$fname: Will now write XML content into $outputDir/$xml\n" if $debug;
	
	#Load XML:Writer
	$writer = XML::Writer->new(OUTPUT => $output, ENCODING => $xmlencoding, DATA_MODE => 1, DATA_INDENT => 1) or croak "cannot create XML::Writer: $!";

	#Start writing
	$writer->xmlDecl(uc($xmlencoding));

	#Write a new SESSIONS tag
	$writer->startTag("sessions");

	
	#For each provided Stop event
	foreach my $sessionId (keys %stop){

		#Open SESSION tag
		$writer->startTag("session", 'sessionId' => $sessionId);
		my $newRef = $stop{$sessionId};
		my %event = %$newRef;
		$stopevents ++;

		#Open START tag
		my %startevent = ();

		#And try to retrieve the respective Start session in orphan hash (based on unique session Id)
		my $starteventref = _findInStartQueue($sessionId);
		$writer->startTag("start");
		if ($starteventref) {
			$startevents ++;
			#Write content
			_writeEvent($starteventref);
		}
		#Close START tag
		$writer->endTag("start");

		#Open INTERIMS tag
		my %interimevents = ();

		#And try to retrieve all the respective Interim sessions in orphan hash (based on unique session Id)
		my $interimeventsref = _findInInterimQueue($sessionId);
		$writer->startTag("interims");
		if ($interimeventsref){
			%interimevents = %$interimeventsref;
			for my $event (sort keys %interimevents){

				#Open INTERIM tag
				$writer->startTag("interim", "id"=>$event);
				
				$interimevents++;
			
				#Write content
				_writeEvent($interimevents{$event});

				#Close INTERIM tag
				$writer->endTag("interim");
			}
		}
		#Close INTERIMS tag
		$writer->endTag("interims");

		#Open STOP tag
		$writer->startTag("stop");

		#Write content
		_writeEvent(\%event);

		#Close STOP tab
		$writer->endTag("stop");

		#Close SESSION tag
		$writer->endTag("session");
	}
	
	
	
	#ALTERNATIVE
	#If User wants all events to be reported, let us process start event
	if ($writeAllEvents){
	
		for my $sessionId (keys %start){
			
			#Open a SESSION Tag
			$writer->startTag("session", 'sessionId' => $sessionId);
			my $newRef = $start{$sessionId};
	
			#Open START tag
			$writer->startTag("start");
			_writeEvent($newRef);
			$startevents++;
			#Close START tag
			$writer->endTag("start");
			
			#Open INTERIMS tag
			my %interimevents = ();
	
			#And try to retrieve all the respective Interim sessions in orphan hash (based on unique session Id)
			my $interimeventsref = _findInInterimQueue($sessionId);
			$writer->startTag("interims");
			if ($interimeventsref){
				%interimevents = %$interimeventsref;
				for my $event (sort keys %interimevents){
	
					#Open INTERIM tag
					$writer->startTag("interim", "id"=>$event);
					
					$interimevents++;
				
					#Write content
					_writeEvent($interimevents{$event});
	
					#Close INTERIM tag
					$writer->endTag("interim");
				}
			}
			#Close INTERIMS tag
			$writer->endTag("interims");
			
			#Open STOP tag
			$writer->startTag("stop");
	
			#Do not write content as all the stop events have been already processed
			
			#Close STOP tab
			$writer->endTag("stop");
	
			#Close SESSION tag
			$writer->endTag("session");
			
			#And delete orphan record
			delete $start{$sessionId};
			
		}
		
		
		#If User wants all events to be reported, let us process interim event
		for my $sessionId (keys %interim){
			
			
			#Open a SESSION Tag
			$writer->startTag("session", 'sessionId' => $sessionId);
			my $newRef = $interim{$sessionId};
			my %interimevents = %$newRef;
		
			#Open START tag
			$writer->startTag("start");
			#Do not write content as all the start events have been already processed		
			#Close START tag
			$writer->endTag("start");

			for my $event (sort keys %interimevents){

				#Open INTERIM tag
				$writer->startTag("interim", "id"=>$event);
			
				$interimevents++;
			
				#Write content
				_writeEvent($interimevents{$event});

				#Close INTERIM tag
				$writer->endTag("interim");
			}

			#Open STOP tag
			$writer->startTag("stop");
			#Do not write content as all the stop events have been already processed
			#Close STOP tab
			$writer->endTag("stop");
	
			#Close SESSION tag
			$writer->endTag("session");
			
			#And delete orphan record
			delete $interim{$sessionId};
			
			
		}
		
		
		
		
	}
	
	#Close SESSIONS tag
	$writer->endTag("sessions");

	#Print sum up
	print "$fname: $stopevents Stop event(s) have been written\n" if $debug;
	print "$fname: $startevents Start event(s) have been found and written\n" if $debug;
	print "$fname: $interimevents Interims event(s) have been found and written\n" if $debug;


	return 1;

}


#--------------------------------------------------
#Remove oldest keys from hash

sub _removeStartOldEntries($){

	my $hashref = shift;
	my %hash = %$hashref;

	#Current Epoch
	my $time = time;

	#Compute threshold in seconds
	my $threshold = $daysForOrphan * 24 * 3600;

	print "$fname: Remove Start orphan older than $daysForOrphan day(s)\n" if $debug;

	#Run through Start hash table
	foreach my $sessionId (keys %hash){
		my $newHashRef = $hash{$sessionId};
		my %newHash = %$newHashRef;

		if (!$newHash{"Event-Timestamp"}){
			#Delete records without date
			print "$fname: Cannot find timestamp, delete entry\n" if $debug > 9;
			delete $hash{$sessionId};
			next;
		}

		#Compute max allowed delta time
		my $mtime = $newHash{"Event-Timestamp"};
		my $delta = $time - $mtime;

		if ($delta > $threshold){
			#Delete oldest records
			print "$fname: delta is $delta - too old orphan\n" if $debug > 14;
			delete $hash{$sessionId};
			next;
		}
	}

	#Return reference of purged hash
	return \%hash;

}


#--------------------------------------------------
#Remove oldest keys from hash

sub _removeInterimOldEntries($){

        my $hashref = shift;
        my %hash = %$hashref;

		#Current Epoch
        my $time = time;

		#Compute threshold in seconds
        my $threshold = $daysForOrphan * 24 * 3600;

		print "$fname: Remove Interim orphan older than $daysForOrphan day(s)\n" if $debug;

		#Run through Interim hash tables
        foreach my $sessionId (keys %hash){
                my $newHashRef = $hash{$sessionId};
                my %newHash = %$newHashRef;
				foreach my $occurence (keys %newHash){
					my $newNewHashRef = $newHash{$occurence};
                	my %newNewHash = %$newNewHashRef;

                	if (!$newNewHash{"Event-Timestamp"}){
							#Delete records without date
                        	print "$fname: Cannot find timestamp, delete entry\n" if $debug > 9;
                        	delete $newHash{$occurence};
                        	next;
                	}

					#Compute max allowed delta time
                	my $mtime = ($newHash{"Event-Timestamp"}) ? $newHash{"Event-Timestamp"} : 0;
                	my $delta = $time - $mtime;

                	if ($delta > $threshold){
							#Delete oldest records
                        	print "$fname: delta is $delta - too old orphan\n" if $debug > 14;
                        	delete $newHash{$occurence};
                        	next;
                	}
		}

		#Remove whole interims events if it does not get any interim session
		delete $hash{$sessionId} if (!scalar (keys %newHash));
        }

		#Return reference of purged hash
        return \%hash;

}




#--------------------------------------------------
#Retrieve an orphan Start event based on sessionId

sub _findInStartQueue($){

	my ($sessionId) = @_;
	my $eventref = $start{$sessionId};
	if (scalar (keys %$eventref)){
		#found Start event
		print "$fname : retrieved Start event for session ID $sessionId\n" if $debug > 9;
		#Remove start event from orphan hash
		delete $start{$sessionId};
	} else {
		#not found
		print "$fname : Orphan stop without start for session ID $sessionId\n" if $debug > 14;
	}

	#Return hash reference of found Start event, undef otherwise
	my $return = (scalar (keys %$eventref)) ? $eventref : undef;
	return $return;

}

#--------------------------------------------------
#Retrieve an orphan interim event based on sessionId

sub _findInInterimQueue($){

	my ($sessionId) = @_;
	my $eventref = $interim{$sessionId};
	if (scalar (keys %$eventref)){
		#found Start event
		print "$fname : retrieved Interim event for session ID $sessionId\n" if $debug > 9;
		#Remove interim event from orphan hash
		delete $interim{$sessionId};
	} else {
		#not found
		print "$fname : Orphan stop without interim for session ID $sessionId\n" if $debug > 14;
	}

	#Return hash reference of found Start event, undef otherwise
	my $return = (scalar (keys %$eventref)) ? $eventref : undef;
	return $return;

}


#--------------------------------------------------
#Convert a set of key value from a given hash ref into XML

sub _writeEvent($){


	my $ref = shift;
	my %hash = %$ref;

	#Check if labels have been supplied
	if (!@labels){
		#If not then add any label (tag) found earlier (during parsing)
		for my $key (keys %tags){
			push (@labels, $key);
		}
		push (@labels, "File");
	}
	

	#convert only the supplied label
	for my $key (@labels){

		#Get this value
		my $value = $hash{$key};
		#Open a new TAG
		$writer->startTag($key); 
		$writer->characters($value) if $value;
		#Close TAG
		$writer->endTag($key);
			
	}


}


#--------------------------------------------------
#Read stored hash if file exists

sub _loadHash() {


        #Load previously stored hashes
        print "$fname: Loading stored data structures\n" if $debug;
        my $startref;
        my $interimref;

		#If file with stored hash exist - START
        if ( -e $startDbm ){
                $startref = lock_retrieve($startDbm) or croak "cannot open file $startDbm: $!";
				$startref = _removeStartOldEntries($startref) if $purgeOrphan;
                %start = %$startref;
				print "$fname: Start hash is now ".scalar(keys %start)." items long\n"; 
        } else {
				print "$fname: Start orphan hash is currently empty\n" if $debug;
				#Does not exist, so initialize a new one
                %start = ();
        }

		#If file with stored hash exist - INTERIM
        if ( -e $interimDbm ){
                $interimref = lock_retrieve($interimDbm) or croak "cannot open file $interimDbm: $!";
				$interimref = _removeInterimOldEntries($interimref) if $purgeOrphan;
                %interim = %$interimref;
				print "$fname: Interim hash is now ".scalar(keys %interim)." items long\n"; 
        } else {
				print "$fname: Interim orphan hash is currently empty\n" if $debug;
				#Does not exist, so initialize a new one
                %interim = ();
        }

}




#--------------------------------------------------
#Retrieve the highest numeric key from a given hash

sub _largestKeyFromHash ($) {

	my ($hash) = shift;
	my ($key, @keys) = keys   %$hash;
	my ($big, @vals) = values %$hash;


	for (0 .. $#keys) {
		if ($vals[$_] > $big) {
			$big = $vals[$_];
			$key = $keys[$_];
		}
	}

	#Return highest key value
	return $key

}



#--------------------------------------------------
#Parse each line given as Input buffer

sub _analyseRadiusLine($$$) {

	
	my ( $line, $lineNumber, $file ) = @_;
	
	#Radius Date Format (1st line)
	#Should contain both MON and DAY (letter) And timestamp HH:MI:SS
	if ($line =~ /^[A-Za-z]{3}.*[A-Za-z]{3}/ && $line =~ /[0-9]{2}[:][0-9]{2}[:][0-9]{2}/){
     
		print "$fname: New event, initialize hash\n" if $debug > 9;   	
		%event = ();

	#Empty line (end of session - Last line)
	} elsif ( $line =~ m/^\n/ || $line =~ m/^[\t\s]+[\n]?$/) {

		my $val = $event{"Acct-Status-Type"} || "";
		my $sessionId = $event{"Acct-Session-Id"} || "";
		my $file = basename($file);

		if ($val =~ /.*[S,s]tart.*/){

			print "$fname: Add event to start hashtable\n" if $debug > 4;
			foreach my $key (keys %event){
				#Store local start event to global Start events hash
				$start{$sessionId}{$key}=$event{$key};
			}
			$start{$sessionId}{File}=$file;

		} elsif ($val =~ /.*[S,s]top.*/){

			print "$fname: Add event to Stop hashtable\n" if $debug > 4;
			foreach my $key (keys %event){
				#Store local stop event to global Stop events hash
				$stop{$sessionId}{$key}=$event{$key};
			}
			$stop{$sessionId}{File}=$file;

		} elsif ($val =~ /.*[I,i]nterim/){

			$interimUpdate = _largestKeyFromHash($interim{$sessionId});
			$interimUpdate ++;
			print "$fname: Add event to Interim hashtable\n" if $debug > 4;
			foreach my $key (keys %event){
				#Store local interim event to global Interims events hash
				$interim{$sessionId}{$interimUpdate}{$key}=$event{$key};
				$interim{$sessionId}{$interimUpdate}{File}=$file;
			}
		} else {
			#Unmanaged event
			print "$fname: unmanaged event, line $lineNumber\n" if $debug;
			return undef;
		}
		

	#Between first and last line, we store any TAG/VALUE found
	#2012-07-28 Allowing space character in value and numbers in key
	} elsif ( my($tag,$val) = ( $line =~ m/^\t([0-9A-Za-z:-]+)\s+=\s+["]?([A-Za-z0-9=\\\.-\_\s]*)["]?.*\n/ ) ) {

		if($tag){
			$tags{$tag}++;
			$event{$tag} = $val;
			print "$fname: $lineNumber: $tag = ".$event{$tag}."\n" if $debug > 9;
		} else {
			print "$fname: Unknown line $lineNumber, cannot find tag/value" if $debug;
			return undef;
		}
		
	} else {

		print "$fname: This line does not follow any known pattern: $line" if $debug;
	}

	#If success
	return 1;

}



END {
	
        #Store computed hash tables
        lock_store \%start, $startDbm or croak "Cannot store Start to file $startDbm: $!";
        lock_store \%interim, $interimDbm or croak "Cannot store Interim to file $interimDbm: $!";
	
}




=head1 NAME

RADIUS::XMLParser - Radius log file XML convertor


=head1 SYNOPSIS

=over 5

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
		) or die "Cannot create Parser: $!";
		
	my $result = $radius->group(\@logs);

=back

=head1 DESCRIPTION


This module will extract and sort any supported events included in a given radius log file. Note that your logfile must contain an empty line at its end otherwise its last event will not be captured.
Events will be grouped by their session ID and converted into XML sessions.
At this time, supported events are the following:

	START
	INTERIM-UPDATE
	STOP


On first step, any event will be stored on different hash tables (with SessionID a unique key).
Then, for each STOP event, the respective START and INTERIM will be retrieved

=over

=item [OPTIONAL] Each found START / INTERIM event will be removed from hash, and final hash will be stored on disk.

=item [OPTIONAL] Only the newest START / INTERIM events will be kept. Oldest ones will be considered as orphan events and will be dropped

=back

Final XML will get the following structure:

	<sessions>
	   <session sessionId=$sessionId>
	      <start></start>
	      <interims>
	         <interim id1></interim>
	      </interims>
	      <stop></stop>
	   </session>
	</sessions>


=head1 Constructor

=over

=item USAGE:

	my $z = RADIUS::XMLParser->new([%params]);

=item PARAMETERS:

See L</Options> for a full list of the options available for this method	
		
=item RETURN:

A radius parser blessed reference

=back

=head1 Options

=over

=item DEBUG

Integer (0 by default) enabling Debug mode.
Regarding the amount of lines in a given Radius log file, debug is split into several levels (1,5,10,15).
	
=item LABELS

Array reference of labels user would like to see converted into XML. 

For instance:

	my @labels = qw(
	Acct-Output-Packets
	NAS-IP-Address
	Event-Timestamp);

Will result on the following XML

	<stop>
		<Acct-Output-Packets></Acct-Output-Packets>
		<NAS-IP-Address></NAS-IP-Address>
		<Event-Timestamp></Event-Timestamp>
	</stop>

If LABELS is not supplied, all the found Key / Values will be written. Else, only these labels will be written.	
FYI, Gettings few LABELS is significantly faster..
Think of it when dealing with large files !

=item AUTOPURGE

Boolean (0 by default) that will purge stored hash reference (Start + Interim) before being used for Event lookup.
Newest events will be kept, oldest will be dropped.
Threshold is defined by below parameter DAYSFORORPHAN

=item DAYSFORORPHAN

Number of days user would like to keep the orphan Start + Interim events.
Default is 1 day; any event older than 1 day will be dropped.
AUTOPURGE must be set to true

=item OUTPUTDIR

Output directory where XML file will be created
Default is '/tmp'
	
=item ALLEVENTS

Boolean (0 by default).
If 1, all events will be written, including Start, Interim and Stop "orphan" records. 
Orphan hash should be empty after processing.
If 0, only the events Stop will be written together with the respective Start / Interims for the same session ID. 
Orphan hash should not be empty after processing.

=item XMLENCODING

Only C<utf-8> and C<us-ascii> are supported 
		
=item ORPHANDIR

Default directory for orphan hash tables stored structure
Default is '/tmp'
		
=item CONTROLDATA

Boolean (0 by default) 
Print out hash table in order to control data structure
These data structure will be written on files, under ORPHANDIR directory
	
=back

=head1 Methods

=over 5

=item $z->group(\@logs)

The C<group> will parse all logs in array reference C<@logs>.
For each log file, events will be retrieved, sorted and grouped by their unique sessionId.
Then, each file will be converted into a XML format.
	
=item USAGE:
	
		my $return = $z->group(\@logs);
	
=item PARAMETER:
	
C<@logs>:
All the radius log file that will be parsed. 
Actually it might save some precious time to parse several logs instead of one by one.
(orphan hash events will be loaded only once).
	
=item GIVE:

	$self->convert();

For each provided log, an XML will be generated. 
	
=item RETURN:

The number of found errors.
	

=back

=head1 EXAMPLE

	
	my @logs = qw(../etc/radius.log);
	my @labels = qw(Event-Timestamp User-Name File);
	
	
	my $radius = RADIUS::XMLParser->new(
		DEBUG=>1, 
		DAYSFORORPHAN=>1, 
		AUTOPURGE=>0, 
		ALLEVENTS=>1, 
		XMLENCODING=>"us-ascii", 
		OUTPUTDIR=>'/tmp/radius',
		LABELS=>\@labels);
		
	my $result = $radius->group(\@logs);


The generated XML will look like the following:
	
	<session sessionId="d537cca0d43c95dc">
	  <start>
	   <Event-Timestamp>1334560899</Event-Timestamp>
	   <User-Name>User1</User-Name>
	   <File>radius.log</File>
	  </start>
	  <interims>
	   <interim id="1">
	    <Event-Timestamp>1334561024</Event-Timestamp>
	    <User-Name>User1</User-Name>
	    <File>radius.log</File>
	   </interim>
	   <interim id="2">
	    <Event-Timestamp>1334561087</Event-Timestamp>
	    <User-Name>User1</User-Name>
	    <File>radius.log</File>
	   </interim>
	  </interims>
	  <stop>
	   <Event-Timestamp>1334561314</Event-Timestamp>
	   <User-Name>User1</User-Name>
	   <File>radius.log</File>
	  </stop>
	 </session>
	


=head1 AUTHOR

Antoine Amend <amend.antoine@gmail.com>

=head1 MODIFICATION HISTORY

See the Changes file.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012 Antoine Amend. All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

#Keep Perl Happy
1;


