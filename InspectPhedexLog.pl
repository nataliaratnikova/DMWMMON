#!/usr/bin/perl

###############################################################################
# Script to analyze the PhEDEx download daemon log. Works with PhEDEx 2.5.x
#
# Author: Derek Feichtinger <derek.feichtinger@psi.ch>
#
# Version info: $Id: InspectPhedexLog.pl,v 1.6 2007/04/23 22:37:42 dfeichti Exp $:
###############################################################################

use strict;
use Getopt::Std;
use Data::Dumper;
use Date::Manip qw(ParseDate UnixDate ParseDateString);
use Time::Local;

my $flag_showErrors=0;
my $flag_rawErrors=0;
my $flag_verbose=0;
my $flag_debug=0;
my $flag_checkdate=0;
my $flag_bunchDetect=0;

my $errmsglen=165; # length of error messages to use (error will be cut)

sub usage {
print <<"EOF";
usage: InspectPhedexLog [options] logfile1 [logfile2 ...]

   Analyses PhEDEx download agent log files

   options:
      -e    also show error statistics (summary over error messages)
         -r    do not try to regexp-process errors messages, but show raw error messages
      -v    verbose   Prints task IDs for the collected errors (useful for closer investigation)
                      Also prints multiply failed files that were never transferred correctly
      -s    start_date   -t end_date

      -b    bunch detection and rate calculation
            (still some problems with correct bunch detection. leading to strange rates for some
             source logs. Do not rely on this).
      -d    debug   Prints a summary line for every single transfer
      -h    display this help

 examples:
   InspectPhedexLog.pl Prod/download
   InspectPhedexLog.pl -evs yesterday -t "2006-11-20 10:30:00" Prod/download
   InspectPhedexLog.pl -es "-2 days"  Prod/download

   without any of the special options, the script will just print
   summary statistics for all download sources.

   Running with the -e option is probably the most useful mode to identify site problems

EOF

}

# A note about the time values used in PhEDEx
#
# t-expire: time when transfer task is going to expire 
# t-assing: time when transfer task was assigned (task was created)
# t-export: time when files where marked as available at source
# t-inxfer: time when download agent downloaded task the file belongs to.
# t-xfer: time when transfer for that particular file starts
# t-done: time when transfer for that particular file finished
#
# Note from D.F.:
# This is not quite correct. Several files in a sequence always get the
# same t-xfer value and nearly identical t-done values (the t-done value
# differences are <0.1s). So these times seem to refer rather to a
# bunch of files and not to the times of particular files.



# OPTION PARSING
my %option=();
getopts("bdehrs:t:v",\%option);


$flag_bunchDetect=1 if(defined $option{"b"});
$flag_showErrors=1 if(defined $option{"e"});
$flag_rawErrors=1 if(defined $option{"r"});
$flag_verbose=1 if(defined $option{"v"});
$flag_debug=1 if(defined $option{"d"});

if (defined $option{"h"}) {
   usage();
   exit 0;
}

my ($dstart,$dend)=(0,1e20);
if (defined $option{"s"}) {
   my $tmp=ParseDate($option{"s"});
   die "Error: Could not parse starting date: $option{s}\n" if (!$tmp);
   $dstart=UnixDate($tmp,"%s");
   #my ($s,$m,$h,$D,$M,$Y) = UnixDate($tmp,"%S","%M","%H","%d","%m","%Y");
   #print "Starting Date: $Y $M $D  $h $m $s ($dstart)\n"; 
   $flag_checkdate=1; 
}
if (defined $option{"t"}) {
   my $tmp=ParseDate($option{"t"});
   die "Error: Could not parse end date: $option{t}\n" if (!$tmp);
   $dend=UnixDate($tmp,"%s");
   $flag_checkdate=1; 
}
   

my @logfiles=@ARGV;

my %sitestat;
my %failedfile;

if ($#logfiles==-1) {
   usage();
   die "Error: no logfile(s) specified\n";
}

my ($datestart,$dateend,$date_old)=0;
my %errinfo;
my %dberrinfo;
my ($date,$task,$from,$stat,$size,$txfer,$tdone,$ttransfer,$fname,$reason,$bsize,$size_sum);
my ($bunchsize,$bunchfiles,$txfer_old,$tdone_old,$closedbunch)=0;
my $line;
my $statstr;
foreach my $log (@logfiles) {
   open(LOG,"<$log") or die "Error: Could not open logfile $log";
   my ($MbperS,$MBperS);
   while($line=<LOG>) {
      if ($line =~ /xstats.*report-code=.*/) {

         ($date,$task,$from,$stat,$size,$txfer,$tdone,$fname) = $line =~
            m/(\d+-\d+-\d+\s+\d+:\d+:\d+):.*task=([^\s]+).*from=([^\s]+).*report-code=([\d-]+).*size=([^\s]+).*t-xfer=([^\s]+).*t-done=([^\s]+).*lfn=([^\s]+)/;
         # report-code=0 means a successful transfer
	 if(! $fname) {
	   die "Error: Parsing problem with line:\n$line";
	 }

         if($flag_checkdate) {
            my ($Y,$M,$D,$h,$m,$s) = $date =~ m/(\d+)-(\d+)-(\d+)\s+(\d+):(\d+):(\d+)/;
            #print "$line\n$date   $Y,$M,$D,$h,$m,$s\n"; #    $epdate $dstart $dend \n";
            my $epdate=timelocal($s,$m,$h,$D,$M-1,$Y);
            next if $epdate < $dstart or $dend < $epdate;
         }

         $dateend=$date; # TODO

	 $closedbunch=0;
         if($stat == 0) {   # successful transfer
             $statstr="OK    ";  ##### sprintf("OK(%4d)  ",$stat);
             $sitestat{"$from"}{"OK"}++;
             $sitestat{"$from"}{"size"}+=$size;
             delete $failedfile{"$fname"} if exists $failedfile{"$fname"};

             # the following is needed because transfer time applies not to a single file but to the bunch
	     if( ! defined $txfer_old || $txfer_old == 0  || $txfer == $txfer_old) {     # try to identify bunches
	       printf STDERR ("WARNING: there may be a transfer time problem (delta t-done=%.4f) in line\n$line\n",$tdone-$tdone_old) if $flag_bunchDetect && abs($tdone-$tdone_old) > 0.2 && $txfer_old != 0;
	       $bunchfiles++;
	       $bunchsize += $size;
	     } else {
                 $closedbunch=1;
	     }
	     #printf ("DEBUG: DIFF %.5f   txfer %.5f    tdone %.5f  \n",$ttransfer - $ttransfer_old,
             #$txfer-$txfer_old, $tdone-$tdone_old);
	     ($txfer_old,$tdone_old) = ($txfer,$tdone);

         } else {
             $failedfile{"$fname"}++;
             $statstr="FAILED";  #sprintf("FAILED(%4d)",$stat);
             $sitestat{"$from"}{"FAILED"}++;

	     # try to collect error information in categories. This needs to be extended for the myriad of SRM
	     # error messages ;-)
	     my ($detail,$validate) = $line =~ m/.*detail=\((.*)\)\s*validate=\((.*)\)\s*$/;
	     if(! $flag_rawErrors) {
	       my $tmp;
	       $detail = substr($detail,0,$errmsglen) . "...(error cut)" if length($detail) > $errmsglen;
	       $detail =~ s/\sid=[\d-]+\s/id=\[id\] /;
	       $detail =~ s/\sauthRequestID \d+\s/authRequestID \[id\] /;
	       $detail =~ s/RequestFileStatus#[\d-]+/RequestFileStatus#\[number\]/g;
	       $detail =~ s/srm:\/\/[^\s]+/\[srm-URL\]/;
	       if( $detail=~/^\s*$/) {$reason = "(No detail given)"}
	       elsif( (($reason) = $detail =~ m/.*(the server sent an error response: 425 425 Can't open data connection).*/)) {}
	       elsif( (($reason) = $detail =~ m/.*(the gridFTP transfer timed out).*/) ) {}
	       elsif( (($reason) = $detail =~ m/.*(Failed SRM get on httpg:.*)/) ) {}
	       elsif( (($reason) = $detail =~ m/.*(Failed on SRM put.*)/) )
		 { $reason =~ s!srm://[^\s]+!\[srm-url\]!; }
	       elsif( (($reason,$tmp) = $detail =~ m/.*(ERROR the server sent an error response: 553 553)\s*[^\s]+:(.*)/) )
		 {$reason .= " [filename]: " . $tmp}
	       elsif( (($reason) = $detail =~ m/(.*Cannot retrieve final message from)/) )
		 {$reason .= "[filename]"}
	       #elsif( $detail =~ /.*RequestFileStatus.* failed with error.*state.*/)
		# {$reason = $detail; $reason =~ s/(.*RequestFileStatus).*(failed with error:).*(state.*)/$1 [Id] $2 $3/;}
	       elsif( $detail =~ /copy failed/ )
		 { $reason = $detail; $reason =~ s/at (\w{3} \w{3} \d+ \d+:\d+:\d+ \w+ \d+)/at \[date\]/g}
	       else {$reason = $detail};
	     } else {$reason = $detail};
	     $errinfo{$from}{$reason}{num}++;
	     push @{$errinfo{$from}{$reason}{tasks}},$task;
         }

#         ($date_old,$from_old,$ttransfer_old)=($date,$from,$ttransfer);

         $datestart=$date if !$datestart;

	 if($closedbunch) {
	   $ttransfer = $tdone_old - $txfer_old;
	   die "ERROR: ttransfer=0 ?????? in line:\n $line\n" if $ttransfer == 0;
	   $sitestat{"$from"}{"ttransfer"}+=$ttransfer;
	   $MbperS=$bunchsize*8/$ttransfer/1e6;
	   $MBperS=$bunchsize/1024/1024/$ttransfer;
	   printf("   *** Bunch:  succ. files: $bunchfiles  size=%.2f GB  transfer_time=%.1f s (%.1f MB/s = %.1f Mb/s)\n"
		  ,$bunchsize/1024/1024/1024,$ttransfer,$MBperS,$MbperS) if $flag_debug && $flag_bunchDetect;

	   $bunchfiles = 1;
	   $bunchsize = $size;
	 }
	 printf("$statstr $from  $fname  size=%.2f GB $date\n",$size/1024/1024/1024)  if $flag_debug;

      }  elsif($line =~ /ORA-\d+.{40}/) {
	my ($ora) = $line =~ m/(ORA-\d+.{40})/;
	($date) = $line =~ m/^(\d+-\d+-\d+\s+\d+:\d+:\d+):/;
	$dberrinfo{$ora}{num}++;
	push @{$dberrinfo{$ora}{"date"}},UnixDate($date,"%s");
      }
    }

   close LOG;

 }


if($flag_showErrors) {
   print "\n\n==============\n";
   print "ERROR ANALYSIS\n";
   print "==============\n";

   if($flag_verbose) {
     print "\nRepeatedly failing files that never were transferred correctly:\n";
     print   "===============================================================\n";
     foreach my $fname (sort {$failedfile{$b} <=> $failedfile{$a}} keys %failedfile) {
       printf("   %3d  $fname\n",$failedfile{"$fname"}) if $failedfile{"$fname"} > 1;
     }
   }


   print "\n\nData base Errors\n";
   print "==================\n";
   foreach my $err (keys %dberrinfo) {
     printf("   %3d  $err\n",$dberrinfo{$err}{num});
     my $h=simpleHisto(\@{$dberrinfo{$err}{"date"}},10);
     printTimeHisto($h);
   }


   print "\n\nError message statistics per site:\n";
   print "===================================\n";
      foreach $from (keys %errinfo) {
         print "\n *** ERRORS from $from:***\n";
         foreach $reason (sort { $errinfo{$from}{$b}{num} <=> $errinfo{$from}{$a}{num} } keys %{$errinfo{$from}}) {
            printf("   %4d   $reason\n",$errinfo{$from}{$reason}{num});
	    print "             task IDs: ", join(",",@{$errinfo{$from}{$reason}{tasks}}) . "\n\n" if $flag_verbose;
         }
      }

   }
print "\nSITE STATISTICS:\n";
print "==================\n";
print "                         first entry: $datestart      last entry: $dateend\n";

my ($MbperS,$MBperS);
foreach my $site (sort {$a cmp $b} keys %sitestat) {
    $sitestat{$site}{"OK"}=0 if ! defined $sitestat{$site}{"OK"};
    $sitestat{$site}{"FAILED"}=0 if ! defined $sitestat{$site}{"FAILED"};
    print "site: $site (OK: " . $sitestat{$site}{"OK"} . " / Err: " . $sitestat{$site}{"FAILED"} . ")";
    printf("\tsucc. rate: %.1f %%", $sitestat{$site}{"OK"}/($sitestat{$site}{"OK"}+$sitestat{$site}{"FAILED"})*100) if ($sitestat{$site}{"OK"}+$sitestat{$site}{"FAILED"}) > 0;
    $sitestat{$site}{"size"}=0 if ! exists $sitestat{$site}{"size"};
    printf("   total: %.1f GB",$sitestat{$site}{"size"}/1e9);

    if ( exists $sitestat{$site}{"ttransfer"} && $sitestat{$site}{"ttransfer"}>0) {
      $MbperS=$sitestat{$site}{"size"}*8/$sitestat{$site}{"ttransfer"}/1e6;
      $MBperS=$sitestat{$site}{"size"}/1024/1024/$sitestat{$site}{"ttransfer"};
      printf("   avg. rate: %.1f MB/s = %.1f Mb/s",$MBperS,$MbperS) if $flag_bunchDetect;
    }
    print "\n";
}






sub simpleHisto {
  my $data = shift; # ref to array of data values
  my $nbins = shift; # number of desired bins

  return undef if $#{@{$data}} < 0;

  my %histo;  # return structure
  my @h=();
  my @xlabel=();

  my $min=@{$data}[0];
  my $max=@{$data}[0];
  foreach my $x (@{$data}) {
    if($x < $min) {
      $min = $x;
      next;
    }
    $max = $x if $x > $max;
  }

  if ($#{@{$data}}==0) {
  }

  if($max==$min) {
    push @h,$#{@$data} + 1;
    push @xlabel,$min;
    %histo=( "value"=> \@h,
	     "xlabel"=> \@xlabel,
	     "binsize"=> undef
	   );
    return \%histo;
  }

  my $binsize = ($max-$min)/$nbins;
  if ($binsize <=0) {
    print STDERR "Error: Binsize=$binsize,  min=$min   max=$max  # datapoints:". $#{@{$data}}+1 . " nbins=$nbins\n";
    print "DATA: " . join(", ",@{$data}) . "\n";
    return undef;
  }

  for(my $n=0; $n<$nbins; $n++) {
    $xlabel[$n] = $min + ($n+0.5) * $binsize;
    $h[$n]=0;
  }

  my $bin;
  foreach my $x (@{$data}) {
    $bin = int(($x - $min)/$binsize);
    $h[$bin]++;
  }

  # need to add topmost bin to bin n-1
  $h[$nbins-1] += $h[$nbins];
  pop @h;

  $histo{value}=\@h;
  $histo{xlabel}=\@xlabel;
  $histo{binsize}=$binsize;

  return \%histo;
}

sub printTimeHisto {
  my $h = shift;

  for(my $i=0;$i<= $#{@{$h->{value}}};$i++) {
    printf("     %6d   %s\n",$h->{value}[$i],
	   UnixDate(ParseDateString("epoch " . int($h->{xlabel}[$i])),"%Y-%m-%d %H:%M:%S"));
  }
}
