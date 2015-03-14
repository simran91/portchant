#!/usr/bin/perl


##################################################################################################################
# 
# File         : portchant.pl
# Description  : pipe's data between two peers
# Original Date: ~1995
# Author       : simran@dn.gs
#
##################################################################################################################

#
# include all required library directories!
#
BEGIN { 
  my $script_dir = "$0";
  if ($script_dir =~ m!/!g) { $script_dir =~ s!(.*)/(.*)!$1!g; }
  else {                      $script_dir = "."; }

  unshift(@INC, "$script_dir/../lib");
}

use strict;
use POSIX;
use FileHandle;
use IO::Socket;
use IPC::Open2;


#
# define the global constants
#
use constant BUFFER_SIZE => 1024;

#
# define some 'global' variables
#

#
# define the internal variables
#
$|         = 1;
$SIG{CHLD} = \&REAPER;


##################################################################################################################
#
# main program
#

#
# predeclare some subroutines... 
#
sub spawn;

#
# define the global variables that we get from the command line parameters
#
my $outfile;              # Then name of the output file
my $logfile;              # Then name of the log file
my $replace_char;         # The character that we must replace all binary data with for loggong purposes
my $localhost;            # The local hostname/ip address we need to bind to
my $localport;            # The local tcp port number we need to bind to
my $remotehost;           # The remote hostname/ip address we will redirect to
my $remoteport;           # The remote tcp port number we will redirect to
my $nofork;               # Set to '1' if the program should not fork itself
my $onthefly;             # The number of seconds we will wait for the entry of remotehost:remoteport
my $pipe;                 # The name of the program that we will pipe to

&getArgs(@ARGV);

#
# create any filehandles needed
#
if ($outfile) { open(OUTFILE, ">> $outfile") || die "could not open outfile $outfile for writing: $!"; 
                OUTFILE->autoflush(1); }

if ($logfile) { open(LOGFILE, ">> $logfile") || die "could not open logfile $logfile for writing: $!"; 
                LOGFILE->autoflush(1); }


#
# let the user know what is happening 
#
if    ($pipe)     { print STDERR "creating route from $localhost:$localport to $pipe\n"; }
elsif ($onthefly) { print STDERR "creating route from $localhost:$localport to whereever specified on input\n"; }
else              { print STDERR "creating route from $localhost:$localport to $remotehost:$remoteport\n"; }

#
# start the appropriate server
#
if ($nofork) {             &redirectServer($localhost, $localport, $remotehost, $remoteport);    }
else 	     { spawn sub { &redirectServer($localhost, $localport, $remotehost, $remoteport); }; }

#
# end of 'main' part!
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : getOntheflyPeerB - listens for incoming connections/data and redirects the data...
#
#      Input : $localhost - the local host to bind/listen on
#              $localport - the local port to bind/listen to
#              $peerBhost - the remote port to connect to       } not required or read if the $onthefly
#              $peerBport - the remote port to connect to       } variable is set
#      Return: none
#
sub getOntheflyPeerB { 
  my ($peerA) = @_;
  my $input;
  my $peerBhost;
  my $peerBport;

  eval {
    local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
    alarm $onthefly;
    while ($input !~ /\n/) {
      $peerA->recv($_, BUFFER_SIZE, 0);
      $input .= $_;
    }
    alarm 0;
  };

  if ($@) { die unless $@ eq "alarm\n"; }   # propagate unexpected errors
  $input =~ /^\s*(.*):(\d+)\s*$/;
  $peerBhost = $1;
  $peerBport = $2;
  if (! ($peerBhost && $peerBport)) {
    # $peerA->send("remotehost and port number not given in correct format\n");
    next;
  }

  return ($peerBhost, $peerBport);

}
#
# 
#
##################################################################################################################



##################################################################################################################
#
# Subroutine : redirectServer - listens for incoming connections/data and redirects the data... 
#
#      Input : $localhost - the local host to bind/listen on
#              $localport - the local port to bind/listen to
#              $peerBhost - the remote port to connect to 	} not required or read if the $onthefly or $pipe
#              $peerBport - the remote port to connect to 	} variable is set
#      Return: none
#
sub redirectServer {

  my ($localhost, $localport, $peerBhost, $peerBport) = @_;

  #
  # setup the incoming socket (peerA)...
  #
  my $peerA_socket = new IO::Socket::INET( Listen    => SOMAXCONN,
			  		   LocalHost => $localhost, 
				           LocalPort => $localport, 
				           ReuseAddr => 1,
			       )
                               || die "can't create listening socket on $localhost:$localport - $!\n"; 

  #
  # accept conections and redirect data back and forth for as many numerous incoming connections
  # that want to connect (upto SOMAXCONN)
  #
  while (my $peerA = $peerA_socket->accept) {
  
    my $peerAhost    = gethostbyaddr($peerA->peeraddr, AF_INET) || $peerA->peerhost;
    my $peerAport    = $peerA->peerport;
    my $peerB        = undef;

    #
    # if $onthefly is set, then we must get peerB details from peerA
    #
    if ($onthefly) { ($peerBhost, $peerBport) = &getOntheflyPeerB($peerA); }

    #
    # ensure what we are redirecting to, write to log and continue with redirection... 
    #
    if ($pipe) { 
      &writeLog("connection from $peerAhost:$peerAport redirecting to $pipe");
    }
    else {
      &writeLog("connection from $peerAhost:$peerAport redirecting to $peerBhost:$peerBport");
      $peerB = new IO::Socket::INET(PeerAddr => $peerBhost,
                                    PeerPort => $peerBport,
                                    Type     => SOCK_STREAM,
                                    Proto    => 'tcp',
                                      )
                             	       || eval { &writeLog("can't connect to $peerBhost:$peerBport (from "
                                                           ."$peerAhost:$peerAport) - $!"); next; };
    }

    #
    # fork so we can spawn a new process and be ready for more connections... 
    #
    unless (my $pid = fork()) {  
      if ($pipe) { &handlePIPE($peerA);                }
      else       { &handleSocketPeers($peerA, $peerB); }
      &writeLog("closing connection from $peerAhost:$peerAport");
      exit(0);
    } 

  } # while
 
}
#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : handleSocketPeers - passes data back and forth between peerA and peerB (both of which 
#                                  will be sockets)
#
#      Input : $peerA - the client who initially requested the redirect/connected
#              $peerB - the socket we are redirecting to... 
#      Return: none
#
sub handleSocketPeers {
  my ($peerA, $peerB) = @_;

  #
  # setup some variables so that we can interrupt/see changes in data from filehandles...
  #
  my $rin  = undef;
  my $rout = undef;

  vec($rin, fileno($peerA),1) = 1;
  vec($rin, fileno($peerB),1) = 1;

  #
  # start the exchanging of data between the peers
  #
  while ( 1 ) {
    my $data = undef;
    if (! select($rout=$rin, undef, undef, undef)) { die "select: $!"; }

    if (vec($rout, fileno($peerA),1)) {
       $peerA->recv($data, BUFFER_SIZE, 0);
       &writeOut(1, $data);
       $peerB->send($data, 0) || last;
    }
    elsif (vec($rout, fileno($peerB),1)) {
       $peerB->recv($data, BUFFER_SIZE, 0);
       &writeOut(2, $data);
       $peerA->send($data, 0) || last;
    }
  }
  
  $peerA->shutdown(2);
  $peerB->shutdown(2);
}
#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : handlePIPE - passes data back and forth between peerA and the PIPE
#
#      Input : $peerA - the client who initially requested the redirect/connected
#      Return: none
#
sub handlePIPE {
  my ($peerA) = @_;
  my ($pipeReader, $pipeWriter);
  my $prompt = "\n$pipe> ";

  #
  # open the filehandles to be associated with the PIPE
  # 
  open2($pipeReader, $pipeWriter, $pipe) || die "Could not open $pipe for reading and/or writing\n";

  #
  # setup some variables so that we can interrupt/see changes in data from filehandles...
  #
  my $rin  = undef;
  my $rout = undef;

  vec($rin, fileno($peerA),1) 	   = 1;
  vec($rin, fileno($pipeReader),1) = 1;
  
  $peerA->send("\n", 0);
  $peerA->send("$prompt", 0);

  #
  # start the exchanging of data between the peers
  #
  while ( 1 ) {
    my $data = undef;

    if (! select($rout=$rin, undef, undef, undef)) { die "select: $!"; }
       
    if (vec($rout, fileno($peerA),1)) {
       $peerA->recv($data, BUFFER_SIZE, 0);
       &writeOut(1, $data);
       print $pipeWriter "$data" || last;
    }
    elsif (vec($rout, fileno($pipeReader),1)) {
       $peerA->send("\n", 0);
       while ($data = <$pipeReader>) { 
         last if ($data =~ /^__END OF PORTCHANT OUTPUT__$/);
         $data =~ s///g;
         &writeOut(2, $data);
         $peerA->send($data, 0) || last;
       }
       $peerA->send("$prompt", 0);
    }
  }

  $peerA->shutdown(2);
  close($pipeReader);
  close($pipeWriter);
  
}
#
#
#
##################################################################################################################


##################################################################################################################
#
# Subroutine : getArgs  - reads in the command line arguments, checks for their validity and returns the values
#                         set.        
#
#      Input : 
#              @ARGV       - Argument array
#
#      Return: 
#              None
#
#      Global Variables Modified: $outfile        
#                                 $replace_char   
#                                 $localhost      
#                                 $localport      
#                                 $remotehost     
#                                 $remoteport     
#                                 $nofork         
#                                 $onthefly       
#                                 $pipe           
#
#
sub getArgs {
  my @ARGV = @_;
  #
  # read in all the arguments and set the variables
  #
  while (@ARGV) { 
    my $arg     = $ARGV[0];
    my $nextarg = $ARGV[1];

    if ($arg =~ /^-o$/i) {
      $outfile = "$nextarg";
      shift(@ARGV);
      shift(@ARGV);
      next;
    }
    elsif ($arg =~ /^-l$/) {
      $logfile = "$nextarg";
      shift(@ARGV);
      shift(@ARGV);
      next;
    }
    elsif ($arg =~ /^-r$/) {
      $replace_char = "$nextarg";
      shift(@ARGV);
      shift(@ARGV);
      next;
    }
    elsif ($arg =~ /^-onthefly$/) {
      $onthefly = "$nextarg";
      if ($onthefly !~ /^\d+$/) {
	&error("Timeout value with -onthefly option is not a valid number!");
      }
      shift(@ARGV);
      shift(@ARGV);
      next;
    }
    elsif ($arg =~ /^-nofork$/) {
      $nofork = 1;
      shift(@ARGV);
      next;
    }
    elsif ($arg =~ /^-lh$/) {
      ($localhost, $localport) = split(/:/, $nextarg, 2);
      if ($localport !~ /^\d+$/ || ! $localhost) {
	&error("Local host or port not in correct format");
      }
      shift(@ARGV);
      shift(@ARGV);
      next;
    }
    elsif ($arg =~ /^-rh$/) {
      ($remotehost, $remoteport) = split(/:/, $nextarg, 2);
      if ($remoteport !~ /^\d+$/ || ! $remotehost) {
	&error("Remote host or port not in correct format");
      }
      shift(@ARGV);
      shift(@ARGV);
      next;
    }
    elsif ($arg =~ /^-pipe$/) {
      $pipe = $nextarg;
      if ((! -x eval {(split(/\s/,"$pipe"))[0]}) || ($pipe =~ /^\s*$/)) {
	&error("Pipe program not defined or not executable");
      }
      
      shift(@ARGV);
      shift(@ARGV);
      next;
    }
    else {
      print "\n\nArgument $arg not understood.\n";
      shift(@ARGV);
    }
  }

  #
  # ensure the validity (and combinations) of the arguments... 
  #
  &error("Local 'host:port' not defined") if (! $localhost || ! $localport);
  &error("Remote 'host:port' or onthefly or pipe not specified") 
    if ((! $remoteport || ! $remotehost) && ! $onthefly && ! $pipe);
  &error("Only one of -rh, -onthefly or -pipe option may be used!") 
    if ((my $sum = defined($onthefly) + defined($remotehost) + defined($pipe)) > 1);
  &error("You can only use the -r option with the -o option") if ($replace_char && ! $outfile);

}
#
#
##################################################################################################################


##################################################################################################################
#
# Subroutine : error  - prints and error message then exits
#
#      Input : 
#              $message   - The error message
#
#      Output: 
#              Error Message
#
sub error {
  my $message = "@_";
  print STDERR "\nError: $message\n\n";
	print STDERR "Please use 'perldoc $0' to see documentation\n\n";
  exit;
}
#
#
#
##################################################################################################################


##################################################################################################################
#
# Subroutine : writeOut - writes the data going each way to the output file
#
#      Input :
#              $direction  - Must be either '1' or '2'. 
#			     Direction 1 = localhost:localport to remotehost:remoteport (peerA -> peerB)
#                            Direction 2 = remotehost:remoteport to localhost:localport (peerB -> peerA)
#              $data       - The data we are writing
#
#      Return:
#              None
#
#      Other : If a replace_char was specified via the -r option, then this subroutine does the 
#              substitution as well
#
sub writeOut {

  return unless ($outfile);
  my ($direction, $data) = @_;

  #
  # get the time to we can log it in the file... 
  #
  my $timenow = time;

  #
  # replace the binary data if we were requested to via the -r option!
  #
  $data = &replaceChar("$data") if ($replace_char);

  #
  # record the data... 
  #
  if ($direction == 1) { 
    if ($pipe) { print OUTFILE "$timenow:$localhost:$localport->$pipe: $data\n"; }
    else       { print OUTFILE "$timenow:$localhost:$localport->$remotehost:$remoteport: $data\n"; }
  }
  elsif ($direction == 2) {
    if ($pipe) { print OUTFILE "$timenow:$remotehost:$remoteport->$pipe: $data\n"; }
    else       { print OUTFILE "$timenow:$remotehost:$remoteport->$localhost:$localport: $data\n"; }
  }
  else {
    die "Could not determine direction of data for logging purposes";
  }

}

#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : writeLog - writes the data (supplied as input) to the logfile
#
#      Input : $data       - The data we are writing
#
#      Return: none
#
sub writeLog {

  return unless ($logfile);
  my ($text) = @_;

  #
  # get the time to we can log it in the file...
  #
  my $timenow = time;

  #
  # record the data/text...
  #
  print LOGFILE "$timenow: $text\n";

}

#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : replaceChar - replaces all binary bits of data to readable via replaceing them with the character
#                            supplied with the -r option
#
#      Input :
#              $data       - The data we are changing
#
#      Return:
#              $data       - The data after all binary bits have been changed to $replace_char
#
sub replaceChar {
  my $data = "@_";

  #
  # declar the final string we are going to hold the data in
  #
  my $final_data = "";

  #
  # define what we assign as readable/unreadable by defining the limits of readable values
  #
  my $first_ascii_value = unpack("c", " ");
  my $last_ascii_value = unpack("c", "~");

  foreach my $char (split(//, "$data")) {
    my $ascii_value = unpack("c", "$char");

    if ($ascii_value < $first_ascii_value || $ascii_value > $last_ascii_value) {
      $char = "$replace_char";
    }

    $final_data .= "$char";
  }

  return("$final_data");

}

#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : spawn - forks code
#
#      Input :
#              $coderef - reference to code you want to 'spawn'
#
sub spawn {
  my $coderef = shift;
  unless (@_ == 0 && $coderef && ref($coderef) eq 'CODE') {
    die "usage: spawn CODEREF";
  }
  my $pid;
  if (!defined($pid = fork)) {
    print STDERR "cannot fork: $!\n";
    return;
  }
  elsif ($pid) {
    # print "begat $pid\n";
    return; # i'm the parent
  }
  # else i'm the child -- go spawn

  exit &$coderef();
}
#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : REAPER - reaps zombie processes
#
sub REAPER {
  my $child;
  our %Kid_Status; # store each exit status
  $SIG{CHLD} = \&REAPER;
  while ($child = waitpid(-1,WNOHANG) > 0) {
    $Kid_Status{$child} = $?;
  }
}
#
#
#
##################################################################################################################












=pod

##################################################################################################################

=head1 NAME 

portchant.pl - Redirect ports from local to local/remote machines by acting as a transparent agent

##################################################################################################################

=head1 DESCRIPTION 

Redirect tcp based ports on local machine to local/remote machines (acts as an 'transparent' agent in the middle)

##################################################################################################################

=head1 REVISION

$Revision: 1.4 $

$Date: 2003/12/03 02:20:42 $

##################################################################################################################

=head1 AUTHOR

simran I<simran@dn.gs>

##################################################################################################################

=head1 BUGS

No known bugs. 

##################################################################################################################

=head1 DIAGRAM

A digram of a running redirection would look like this:

  -------------         -----------------------         -------------
  |   Peer    | ======> |   Agent 	      | ======> |   Peer    |
  |     A     | <====== |   (portchant)       | <====== |     B     |
  -------------         -----------------------         -------------

##################################################################################################################

=head1 PARAMETERS

B<Mandetory Parameters>

I<-lh localhost:localport>   The local hostname/ip and port number to bind to and redirect from

One of: 

I<-rh remotehost:remoteport> The remote hostname/ip and port number to redirect to

I<-onthefly timeout>         Assign remotehost:remoteport upon each connection.
                             If remotehost:remoteport is not supplied within 'timeout' 
                             seconds, then close connection!
                             When a conneciton to the localhost:localport is made 
                             the first thing that must be entered is hostname:portnumber 
                             followed by a return/enter! That particular connection will 
                             then (until the connection is closed) be redirected to 
                             hostname:portnumber


I<-pipe program> (please see souce of this script to see the documentation properly for this feature)
 
        * Due to issues with programs usually buffering (see 'perldoc IOC::Open2' for
          more details) you _must_ pipe to a program that meets the following conditions
         
          1. Prints '__END OF PORTCHANT OUTPUT__' on a _line by itself_ to indicate the end
             of output from the pipe for a parcitular command
             (see example below)
 
 -------------------------------------------------------------------------
 
  -- pipe_shell.pl ------
  #!/usr/bin/perl
 
  $| = 1;
 
  while ($command=<>) {
    $command =~ s/(\r|\n)$//g;
    $out     = `sh -c "$command 2>&1"`;
    $out     =~ s/\r//g;
    print $out;
    print "\n__END OF PORTCHANT OUTPUT__\n";
  }
 
  # NOTE: The 'Carrat M' (^M) above is not literally a 'Carrat M' but a control character
  #       achieved on unix by typing 'Control-V Control-M'. As a result, you CANNOT COPY
  #       PASTE the above code (using a mouse anyway!).
 
  -----------------------
 
  and then do:
 
        ./portchant.pl -nofork -lh localhost:9999 -pipe "./pipe_shell.pl"
 
  ------------------------------------------------------------------------
 


B<Optional Parameters>

One of:

I<-o outfile>  Records data sent back and forth between peers in the file 'outfile'

Any of: 

I<-r char>     Only valid with the I<-o> argument. Replaces any binary characters
               with 'char' before writing to outfile.

I<-nofork>     Do not fork the program on startup (keep in foreground)

I<-l logfile>  Logs information about hosts that connect and use the service (logs to 'logfile')


##################################################################################################################

B<Examples> 

portchant.pl -lh localhost:2345 -rh abc.net:23

portchant.pl -lh 192.168.0.100:4567 -onthefly 7

portchant.pl -nofork -mo data -r _ -localhost:2345 -rh abc.net:6789

portchant.pl -o data.log -r _ -lh localhost:2345 -rh faure.cse.unsw.edu.au:23

##################################################################################################################

=cut
