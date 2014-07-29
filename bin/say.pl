#!/usr/bin/perl

use strict;
use warnings;

use IO::File;

my $sock = IO::File->new();

unless(open($sock, '>', "/tmp/bytetrain.in")) {
	print "Failed to open fifo: $!\n";
	exit 1;
}

$sock->autoflush(1);

my $args = join(' ', @ARGV);
my $i = $sock->print($args . "\n");

print "i = $i\n";

