#!/usr/bin/perl

##################################################################################################################
# 
# File         : pipe_shell.pl
# Description  : used in conjunction with portchant.pl
# Original Date: ~1995
# Author       : simran@dn.gs
#
##################################################################################################################

#
# This file accompanies the portchant.pl to make it simple to have a "pipe" command ready at your disposal
# should you wish to use the "-pipe" option in portchant.pl
#

$| = 1;
while ($command=<>) {
  $command =~ s/(|\n)$//g;
  $out = `sh -c "$command 2>&1"`;
  $out =~ s///g;
  print $out;
  print "\n__END OF PORTCHANT OUTPUT__\n";
}

