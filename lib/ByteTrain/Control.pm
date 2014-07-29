package ByteTrain::Control;

# The Bytetrain - Gcode sender for 3D Printers and other gcode talkers
# (C) Ralph Bolton (github@coofercat.com), GNU Public License v2
# Written July 2014.

# This module takes care of the control port for the Bytetrain.
# It opens a read FIFO and a write FIFO in /tmp. It then works
# with the rest of the Bytetrain to have the FDs watched and
# processed at the right times to get things done.

use Exporter;
use vars qw($VERSION @ISA);

$VERSION     = 1.0;
@ISA         = qw(Exporter);

use strict;
use warnings;

use IO::File;

use constant READ_BUF_MAX_SIZE => 1024;
use constant WRITE_BUF_MAX_LINES => 100;

sub new {
  my ($class, $readers, $writers) =@_;
  
  my $self = {};

  bless $self, $class;

  $self->{VERBOSITY} = 10;

  $self->{READERS} = $readers;
  $self->{WRITERS} = $writers;

  # Attempt to open a unix domain stream socket in /tmp
  my $in_name = '/tmp/bytetrain.in';
  my $out_name = '/tmp/bytetrain.out';

  my $in_fd = IO::File->new();
  my $out_fd = IO::File->new();

  unless (-p $in_name) { system("mkfifo -m 0666 $in_name"); }
  unless (-p $out_name) { system("mkfifo -m 0666 $out_name"); }

  if(!open($in_fd, '+<', $in_name)) {
    $self->print(10, "Open of input pipe failed: $!");
    exit 1;
  }
  if(!open($out_fd, '+<', $out_name)) {
    $self->print(10, "Open of output pipe failed: $!");
    exit 1;
  }

  $self->{IN_FD} = $in_fd;
  $self->{IN_FD}->autoflush(1);
  $self->{IN_FD}->blocking(0);

  $self->{OUT_FD} = $out_fd;
  $self->{OUT_FD}->autoflush(1);

  $self->{READ_BUF} = '';
  $self->{WRITE_BUF} = [];
  $self->{BUFFER_FULL} = 0;

  $self->{READERS}->add_fd($self->{IN_FD}, $self);
  $self->{WRITERS}->add_fd($self->{OUT_FD}, $self);

  return $self;
}

sub print {
  my ($self, $verbosity, $thing) = @_;

  if($verbosity >= $self->{VERBOSITY}) {
    print "Control: $thing\n";
  }
}

# write_buffer - put something in our buffer for writing
# whenever our FD becomes writable. 
sub write_buffer {
  my ($self, $thing) = @_;
  push @{$self->{WRITE_BUF}}, $thing;
  # Ask for our outgoing FD to be watched
  $self->{WRITERS}->add_fd($self->{OUT_FD}, $self);
}

# write_fd - write something from the buffer to the outgoing
# FD. We don't empty the buffer here, we just write one thing
# (with the expectation that doing so won't block). It means
# we write one thing, check the FD and write another.
sub write_fd {
  my ($self) = @_;
  my $thing = shift(@{$self->{WRITE_BUF}});
  if($thing) {
    $self->print(5, "Sending >$thing< down out pipe...");
    $self->{OUT_FD}->print("$thing\n");
  }
  if($#{$self->{WRITE_BUF}} < 0) {
    # Buffer is empty, so take us out of the wait for writable
    $self->{WRITERS}->remove_fd($self->{OUT_FD});
  }
}

# read_fd - read a block of data from the in-FIFO. We don't
# know how much to read, so ask for 4K. It's unlikely that any
# read is more than a few bytes, so this is probably overkill.
# Whatever we do read, we throw it onto our buffer for later
# processing.
sub read_fd {
  my ($self) = @_;

  my $buffer = '';
  my $i = $self->{IN_FD}->read($buffer, 4096);
  $self->print(5, "Read $i bytes from FD: $buffer");
  my $fd = $self->{IN_FD};
  if(!defined($i)) {
    # Looks like EOF or something
    $self->print(10, "Error reading socket: $!");
    return;
  } elsif($i > 0) {
    $self->{READ_BUF} .= $buffer;
    # See if the buffer is sufficiently full now
    if(length($self->{READ_BUF}) >= 2048) {
      # Buffer sufficiently big - stop trying to read any more
      $self->{READERS}->remove_fd($self->{IN_FD});
      $self->{BUFFER_FULL} = 1;
    }
  }
}

# read_buffer - read a line from our internal buffer. The buffer
# needs to be filled by read_fd from time to time. This method
# snips a bit of text off the buffer to sort of "pop" a line off
# the buffer. It understands that it might have got a partial
# line at the end of the buffer, which it'll refuse to return
# to the caller until a line terminator is added to the buffer.
sub read_buffer {
  my ($self) = @_;

  # We need to 'pop' a command off the read buffer. It's a string
  # with some new lines in it, so pull something off it and return
  # it. Since this is a control port, we're not expecting too
  # many schenanigans here - so don't need to be super-defensive
  # about the lines we're reading and whatnot. Just skip blank lines
  # and remove comments.
  while(length($self->{READ_BUF}) > 0) {
    my $end = index($self->{READ_BUF}, "\n");
    if($end == 0) {
      # This is effectively an empty line - skip it
      $self->{READ_BUF} = substr($self->{READ_BUF}, 1);
      next;
    } elsif($end > 0) {
      # Got something that looks worthwhile - grab it and look at it
      my $string = substr($self->{READ_BUF}, 0, $end);
      # Remove that string from the buffer (inc. the \n)
      $self->{READ_BUF} = substr($self->{READ_BUF}, $end + 1);
      # Remove comments
      $string =~ s/#.*$//;
      # Skip blanks
      next if($string =~ /^\s*$/);
      # We've got something that looks sane - return it
      return $string;
    } else {
      # Got no index back from the buffer. Buffer is most
      # probably empty or partially filled
      # Just bail out so that we keep looking for more
      last;
    }
  }
  # We've either balied out of the loop, or have run out of
  # buffer.
  # Make sure we're looking out for more to read
  if($self->{BUFFER_FULL} && length($self->{READ_BUF}) < 2048) {
    $self->{READERS}->add_fd($self->{IN_FD}, $self);
  }
  return undef;
}

1;
# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
