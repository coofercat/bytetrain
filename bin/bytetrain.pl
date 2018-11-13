#!/usr/bin/perl -w

use strict;
use warnings;

# Make relative 'use' work
BEGIN {
  use File::Basename;
  chdir(dirname($0));
}

use lib '../cpan';
use lib '../lib';

use ByteTrain;

MAIN: {
  select(STDERR);
  $| = 1;
  select(STDOUT);
  $| = 1;
  my $train = ByteTrain->new();

  eval {
    $train->run();
  };
  if($@) {
    print "Bytetrain error:\n";
    print $@;
  }
}

# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
