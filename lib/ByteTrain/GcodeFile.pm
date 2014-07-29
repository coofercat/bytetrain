package ByteTrain::GcodeFile;

# The Bytetrain - Gcode sender for 3D Printers and other gcode talkers
# (C) Ralph Bolton (github@coofercat.com), GNU Public License v2
# Written July 2014.

# This module is responsible for reading a file of gcode on disk
# and returning lines from it. It understands line numbers and
# checksumming, and has a small reply buffer so can rewind to
# the right place if there's a serial transfer error.
#
# One of the main aims of the design of this module is to keep the
# memory footprint small. For that reason, we don't do anything like
# read the whole file into memory.

use Exporter;
use vars qw($VERSION @ISA);

$VERSION     = 1.0;
@ISA         = qw(Exporter);

use strict;
use warnings;

use constant READ_CHUNK_SIZE => 1024;
use constant RAW_LINES_LOW => 10;
use constant RAW_LINES_HIGH => 100;
use constant REWIND_LINES => 10;

use IO::File;

sub new {
  my ($class, $readers) =@_;
  
  my $self = {};

  bless $self, $class;

  $self->{VERBOSITY} = 10;

  $self->{CHUNK} = 0;

  $self->{READERS} = $readers;

  $self->{FD} = undef;
  $self->reset();

  return $self;
}

sub print {
  my ($self, $verbosity, $thing) = @_;

  if($verbosity >= $self->{VERBOSITY}) {
    print "Gcode: $thing\n";
  }
}

sub reset {
  my ($self) = @_;

  $self->print(1,"Reset");

  $self->{RAW_LINES} = [];
  $self->{READ_BUF} = '';
  $self->{GCODE_N} = 1;
  $self->{LINES_READ} = 0;
  $self->{GCODE_READ} = 0;
  $self->{GCODE_POPPED} = 0;
  $self->{PROCESS_GCODE} = 0;

  $self->{REWIND_LINES} = [];
  $self->{REWIND_INDEX} = undef;

  $self->{FILENAME} = undef;
}

# Return some internal state to the caller
sub status {
  my ($self) = @_;

  return {
    'lines_read' => $self->{LINES_READ},
    'gcode_read' => $self->{GCODE_READ},
    'gcode_popped' => $self->{GCODE_POPPED},
    'filename' => $self->{FILENAME},
    'gcode_open' => defined($self->{FD}) ? 1 : 0,
    'gcode_okay' => $#{$self->{RAW_LINES}} >= 0 ? 1 : 0,
  };
}

# Open a file and tell the Bytetrain to watch the resulting
# FD so that we get called to read from the FD in the future.
sub open_gcode {
  my ($self, $filename) = @_;

  # First, try to close anything that's open
  $self->close_gcode();

  my $fd = IO::File->new();
  if(open($fd, '<', $filename)) {
    # File is open
    $self->{FD} = $fd;
    $self->reset();
    $self->{PROCESS_GCODE} = 1;
    $self->{FILENAME} = $filename;
    # Put ourselves into the select so that we read a chunk of file out
    $self->{READERS}->add_fd($self->{FD}, $self);
    $self->print(1,"File $filename now open");
  } else {
    # $! is set :-)
    $self->print(1,"Failed to open $filename: $!");
    return 0;
  }
  return 1;
}

# Close a gcode file and forget about it
sub close_gcode {
  my ($self) = @_;

  if(defined($self->{FD})) {
    $self->{READERS}->remove_fd($self->{FD});
    close($self->{FD});
    $self->{FD} = undef;
    $self->print(1,"File closed");
    $self->{PROCESS_GCODE} = 0;
  }
  return 1;
}

# private method to process a chunk of file pulled in from disk.
sub _handle_buffer {
  my ($self, $buffer) = @_;

  my $pre = $self->{READ_BUF};

  if(length($buffer) > 0) {
    # Got a chunk of text, so add it to the buffer,
    # then split it into lines.
    $self->{READ_BUF} .= $buffer;
  }
 
  # Here, we use limit = -1 to say "give us an empty
  # line on the end if the string ends in a newline". 
  my @lines = split(/\r?\n\r?/, $self->{READ_BUF}, -1);

  # If we just added a bit of buffer on, then we
  # may have picked up a partial line on the end.
  # We just put this back on the buffer to use it
  # next time (when the read returns 0, we'll be
  # called with zero length buffer).
  if(length($buffer) > 0) {
    $self->{READ_BUF} = pop(@lines);
  }

  $self->{LINES_READ} += $#lines + 1;

  # Remove comments from the gcode:
  map {
    $_ =~ s/\s*[;#].*$//;               # Anything after a semicolon or hash
    $_ =~ s/\s*\([^\)]*\)\s*$//g;       # Anything inside brackets
  } @lines;

  # Skip (now?) blank lines
  @lines = grep(!/^\s*$/, @lines);

  $self->{GCODE_READ} += $#lines + 1;

  # Now add whatever we have left to the raw buffer
  # Skip any blank lines
  push @{$self->{RAW_LINES}}, @lines;

  # If the raw buffer is now above the high watermark
  # then turn ourselves off for a while until it empties
  if($#{$self->{RAW_LINES}} >= RAW_LINES_HIGH) {
    $self->{READERS}->remove_fd($self->{FD});
  }

  return 1;
}

# read_fd - actually read a chunk of characters from a file.
# This is called by the Bytetrain when our FD is ready for
# reading.
sub read_fd {
  my ($self) = @_;

  my $buffer = '';
  my $i = $self->{FD}->read($buffer, READ_CHUNK_SIZE);
  $self->print(5, "Read $i bytes from FD");
  if(!defined($i)) {
    # Looks like EOF or something
    $self->print(10, "Error reading file: $!");
    return;
  } elsif($i > 0) {
    $self->_handle_buffer($buffer);
  } else {
    # Read 0 - that means EOF
    # We may have a line left in our buffer (that we thought
    # was a partial when we received it)
    $self->_handle_buffer('');
    $self->print(5,"Reached EOF - switching ourselves off");
    $self->close_gcode();
  }

  return 1;
}

# gcode - return a line of Gcode to be sent to the printer.
# The line returned will be prefixed with a line number and
# suffixed with a checksum
sub gcode {
  my ($self) = @_;

  # If we've got a rewind index, then we've been asked to
  # replay a few lines
  if(defined($self->{REWIND_INDEX})) {
    my $gcode = ${$self->{REWIND_LINES}}[$self->{REWIND_INDEX}];
    $self->{REWIND_INDEX}++;
    # If we've incremented the index beyond the end of the array
    # then we're done rewinding and can carry as normal next time
    $self->{REWIND_INDEX} = undef if($self->{REWIND_INDEX} > $#{$self->{REWIND_LINES}});

    $self->print(5, "Replaying $gcode");

    return $gcode;
  }

  # Unshift something from the raw buffer and wrap it in
  # a line number and checksum
  my $line = shift(@{$self->{RAW_LINES}});
  if(!defined($line)) {
    # Something weird in the list, or more likely we've hit the end of it
    return undef;
  }

  # Prefix the line with the line number (this needs to be on before
  # we calculate the checksum)
  $line = 'N' . $self->{GCODE_N} . ' ' . $line;

  # Checksum calculation...
  my $checksum = 0;
  foreach my $chr (split(//, $line)) {
    $checksum = ($checksum ^ ord($chr)) % 255;
  }

  # Add the checksum to the end of the gcode
  my $gcode = "$line*$checksum";

  # Maintain a rewnd buffer
  push @{$self->{REWIND_LINES}}, $gcode;
  shift(@{$self->{REWIND_LINES}}) if($#{$self->{REWIND_LINES}} >= REWIND_LINES);

  # Remember that next time we'll use the next line
  $self->{GCODE_N}++;

  # Also note that we've popped another line off the file
  $self->{GCODE_POPPED}++;

  # If the raw buffer is now too small, add ourselves to the read select
  # so that we get to read another chunk of file
  if($self->{FD} && $#{$self->{RAW_LINES}} < RAW_LINES_LOW) {
    $self->{READERS}->add_fd($self->{FD}, $self);
  }
  
  return $gcode;
}

# Rewind to a previously sent line of gcode. This just tells gcode()
# to send something in the buffer, but to do that, we have to work
# out which line to rewind to. To do that, we have to examine the
# lines in the buffer.
sub rewind {
  my ($self, $rewind_to) = @_;

  # Step through the rewind buffer looking for the desired N
  # If we find it, remember its index
  my $i = 0;
  for($i = $#{$self->{REWIND_LINES}}; $i >= 0; $i--) {
    if(${$self->{REWIND_LINES}}[$i] =~ /^N$rewind_to /) {
      # Remember this point in the array
      # so that we step forwards from here on in
      $self->{REWIND_INDEX} = $i;
      $self->print(3,"Rewound to index $i");
      return 1;
    }
  }
  # Didn't find our desired N
  return 0;
}

1;
# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
