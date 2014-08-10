package ByteTrain::Stacktrace;

# The Bytetrain - Gcode sender for 3D Printers and other gcode talkers
# (C) Ralph Bolton (github@coofercat.com), GNU Public License v2
# Written July 2014.

use Exporter;
use vars qw($VERSION @ISA);

$VERSION     = 1.0;
@ISA         = qw(Exporter);

use strict;
use warnings;

sub print {
  print "Start of stacktrace:\n";
  for(my $i = 0; $i <= 10; $i++) {
    my @caller = caller($i);
    last if($#caller == -1);
    printf(" %d: %s::%s in %s line %s\n",
      $i,
      $caller[0], # package
      $caller[3], # subroutine
      $caller[1], # filename
      $caller[2], # line
    );
  }
  print "End of stacktrace.\n";
}

1;
# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
