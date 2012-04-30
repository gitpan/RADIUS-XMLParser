package RADIUS::XMLParser;

use strict;
use warnings;

use Storable qw(lock_store lock_retrieve);
use Carp;
use Data::Dumper;
use File::Basename;
use XML::Writer;
use IO::File;

our $VERSION = '1.00';

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
	$xml =~ s/\.log/\.xml/g;

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
		print "$fname : Found event for session ID $sessionId\n" if $debug > 9;
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
		print "$fname : Found event for session ID $sessionId\n" if $debug > 9;
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
	
	#New Radius Date Format (1st line)
	if ( $line =~ /^[A-Za-z]{3}[,]\s[0-9 ]{2}\s[A-Za-z]{3}\s[0-9]{4}\s[0-9]{2}[:][0-9]{2}[:][0-9]{2}[.][0-9]{3}\n/ ) {
	
		#Initialize local hash
		%event = ();

	#Empty line (end of session - Last line)
	} if ( $line =~ m/^\n/ ) {

		# End of section reached, store local results to global hash
		my $val = $event{"Acct-Status-Type"} || "";
		my $sessionId = $event{"Acct-Session-Id"} || "";
		my $file = basename($file);

		if ($val =~ /.*[S,s]tart.*/){

			print "$fname: Add event to start hashtable\n" if $debug > 9;
			foreach my $key (keys %event){
				#Store local start event to global Start events hash
				$start{$sessionId}{$key}=$event{$key};
			}
			$start{$sessionId}{File}=$file;

		} elsif ($val =~ /.*[S,s]top.*/){

			print "$fname: Add event to Stop hashtable\n" if $debug > 9;
			foreach my $key (keys %event){
				#Store local stop event to global Stop events hash
				$stop{$sessionId}{$key}=$event{$key};
			}
			$stop{$sessionId}{File}=$file;

		} elsif ($val =~ /.*[I,i]nterim/){

			$interimUpdate = _largestKeyFromHash($interim{$sessionId});
			$interimUpdate ++;
			print "$fname: Add event to Interim hashtable\n" if $debug > 9;
			foreach my $key (keys %event){
				#Store local interim event to global Interims events hash
				$interim{$sessionId}{$interimUpdate}{$key}=$event{$key};
				$interim{$sessionId}{$interimUpdate}{File}=$file;
			}
		} else {
			#Unmanaged event
			print "$fname: unmanaged event [$val], line $lineNumber\n" if $debug > 4;
			return undef;
		}
		

	#Between first and last line, we store any TAG/VALUE found
	} elsif ( my($tag,$val) = ( $line =~ m/^\t([A-Za-z-]+) = ["]?([A-Za-z0-9=\\\.-]*)["]?\n/ ) ) {

		if($tag){
			$tags{$tag}++;
			$event{$tag} = $val;
			print "$fname: $lineNumber: $tag = ".$event{$tag}."\n" if $debug > 14;
		} else {
			print "$fname: Unknown line $lineNumber, cannot find tag/value" if $debug > 4;
			return undef;
		}
		
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
Radius log file extracter


=head1 DESCRIPTION
This module will extract any supported event included in a given radius log file. All events will then be written (converted) into XML sessions afterwards.
At this time, supported events are the following:

-Start
-Interim-Update
-Stop

Events will be stored on different hash tables with SessionID as a unique key.
The Start and Interims set of event will be stored on File in order to get easily retrieved afterwards (e.g. once all the files has been fully parsed).

For each Stop event, this module will retrieve the respective Start and Interim events based on Session ID key.

[OPTIONAL] Each found Start / Interim event will be removed from hash, and final hash will be stored.
[OPTIONAL] Only the newest Start / Interim events will be kept. Oldest ones will be considered as orphan events and will be dropped


Final XML will get the following structure:

<sessions>
   <session sessionId=$sessionId>
      <start></start>
      <interims>
         <interim id1></interim>
         ...
      </interims>
      <stop></stop>
   </session>
   ...
</sessions>


=head2 FUNCTIONS


new()
	
	USAGE:
	
		my $parser = RADIUS::XMLParser->new([%params]);
	
	PARAMETERS:
	
		DEBUG
			Enable Debug on this module (default off).
			Regarding the amount of lines in a given Radius log file, debug is split into several levels (1,5,10,15)
		
		LABELS
			Array reference of any label that will be written on XML. 
	
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
	
			If LABELS not supplied, all the found Key / Values will be written.
			If LABELS supplied, only these supplied labels will be written
			
			Gettings few LABELS is significantly faster.. Think of it when dealing with large files !
	
		AUTOPURGE
			Boolean (0 by default) that will purge stored hash reference (Start + Interim) before being used for Event lookup.
			Newest events will be kept, oldest will be dropped.
			Threshold is defined by below parameter DAYSFORORPHAN
	
		DAYSFORORPHAN
			Number of days we would like to keep the orphan Start + Interim events.
			Default is 1 day, meanining that at startup, any event older than 1 day will be dropped.
			In order to be taken into account, above parameter AUTOPURGE must be set to true (i.e. 1)
	
		OUTPUTDIR
			Output directory where XML file will be created
			Default is '/tmp'
		
		ALLEVENTS
			Boolean (0 by default) that will allow user to convert every found events (Start / Stop / Interim).
			If 1, then all events will be written, including Start, Interim and Stop "orphan" records. Orphan hash should be empty after processing.
			If 0, then only the events Stop will be written together with the respective Start / Interims for the same session ID. Orphan hash should not be empty after processing.
	
		XMLENCODING
			Default UTF-8, this can be changed to us-ascii
			Only utf-8 and us-ascii are supported 
			
		ORPHANDIR
			Default directory for orphan hash tables stored structure
			Default is '/tmp'
			
		CONTROLDATA
			Boolean (0 by default) that will print out any hash table in order to control data structure
			These data structure will be written on files, under ORPHANDIR directory
			
			
	RETURN:
	
		A radius parser handler (hash reference)


group()

	
	USAGE:
	
		my $return = $parser->group(\@logs);
	
	PARAMETER:
	
		\@logs:
		All the radius log file that will be parsed. 
		Actually it might save some precious time to parse several logs instead of one by one as the hash of orphan events will be loaded only once.
	
	CALL:
	
		$self->convert();
		For each parsed log, an XML will be generated. See above parameters of new constructor for XML options.
	
	RETURN:
	
		The number of found errors
	



=head2 EXAMPLE



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
   <User-Name>41794077013</User-Name>
   <File>radius.log</File>
  </start>
  <interims>
   <interim id="1">
    <Event-Timestamp>1334561024</Event-Timestamp>
    <User-Name>41794077013</User-Name>
    <File>radius.log</File>
   </interim>
   <interim id="2">
    <Event-Timestamp>1334561087</Event-Timestamp>
    <User-Name>41794077013</User-Name>
    <File>radius.log</File>
   </interim>
  </interims>
  <stop>
   <Event-Timestamp>1334561314</Event-Timestamp>
   <User-Name>41794077013</User-Name>
   <File>radius.log</File>
  </stop>
 </session>



=head1 AUTHOR

Antoine Amend <antoine.amend@gmail.com>

=cut





#Keep Perl Happy
1;


