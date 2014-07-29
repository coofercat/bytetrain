#!/usr/bin/perl

use strict;
use warnings;

use IO::File;
use POSIX;

$| = 1;

my $sock = IO::File->new();

unless(open($sock, '+<', "/tmp/bytetrain.out")) {
        print "Failed to open fifo: $!\n";
        exit 1;
}

$sock->autoflush(1);

while(<$sock>) {
        my $line = $_;
        my $datetime = POSIX::strftime("%Y/%d/%m %H:%M:%S", localtime(time()));
        print "$datetime: " . $_;
}

