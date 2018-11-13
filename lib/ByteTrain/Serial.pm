package ByteTrain::Serial;

# The Bytetrain - Gcode sender for 3D Printers and other gcode talkers
# (C) Ralph Bolton (github@coofercat.com), GNU Public License v2
# Written July 2014.

# This module handles everything to do with the serial port.
# On connecting to an Ultimaker, we have to ensure we do a proper
# DTR style reset. We also have to use an honest-to-goodness FD
# and not the object style access that Device::SerialPort gives us.
# As such, this is all a bit of a hack up to get it all working.

use Exporter;
use vars qw($VERSION @ISA);

$VERSION     = 1.0;
@ISA         = qw(Exporter);

use strict;
use warnings;

use IO::File;
use IO::Select;
use Device::SerialPort;

use constant READ_BUF_MAX_SIZE => 1024;
use constant WRITE_BUF_MAX_LINES => 100;

sub new {
  my ($class, $readers, $writers) =@_;
  
  my $self = {};

  bless $self, $class;

  $self->{READERS} = $readers;
  $self->{WRITERS} = $writers;

  $self->{FD} = undef;
  $self->{FILENAME} = undef;
  $self->{SPEED} = 0;

  $self->{READ_BUF} = '';
  $self->{WRITE_BUF} = [];
  $self->{READ_BUFFER_FULL} = 0;

  $self->{VERBOSITY} = 10;

  return $self;
}

sub print {
  my ($self, $verbosity, $thing) = @_;

  if($verbosity >= $self->{VERBOSITY}) {
    print "Serial: $thing\n";
  }
}

sub clear_buffers {
  my ($self) = @_;
  $self->{READ_BUF} = '';
  $self->{WRITE_BUF} = [];
  $self->{READ_BUFFER_FULL} = 0;
}

sub start_writing {
  my ($self) = @_;
  if(defined($self->{FD})) {
    $self->{WRITERS}->add_fd($self->{FD}, $self);
    return 1;
  }
  return 0;
}

  

# from https://github.com/henryk/perl-baudrate/blob/master/set-baudrate.pl
sub set_baudrate(*;$$) {
  my ($fh, $direction, $baudrate) = @_;

  my %constants = (
    "TCGETS2" => 0x802C542A,
    "TCSETS2" => 0x402C542B,
    "BOTHER" => 0x00001000,
    "CBAUD" => 0x0000100F,
    "termios2_size" => 44,
    "c_ispeed_size" => 4,
    "c_ispeed_offset" => 0x24,
    "c_ospeed_size" => 4,
    "c_ospeed_offset" => 0x28,
    "c_cflag_size" => 4,
    "c_cflag_offset" => 0x8,
  );
  
  # We can't directly use pack/unpack with a specifier like "integer of x bytes"
  # Instead, check that the native int matches the corresponding *_size properties
  # Should there be a platform where that isn't the case, we need to find a different
  # way (such as using bitstrings and performing the integer conversion ourselves)
  return -2 if (length pack("I", 0) != $constants{"c_ispeed_size"});
  return -2 if (length pack("I", 0) != $constants{"c_ospeed_size"});
  return -2 if (length pack("I", 0) != $constants{"c_cflag_size"});
  
  # First: Initialize the termios2 structure to the right size
  my $to = " "x $constants{"termios2_size"};
  
  # Second: Call TCGETS2
  ioctl($fh, $constants{"TCGETS2"}, $to) or return -1;
  
  # Third: Modify the termios2 structure
  # A: Extract and modify c_cflag
  my $cflag = unpack "I", substr($to, $constants{"c_cflag_offset"}, $constants{"c_cflag_size"});
  $cflag &= ~$constants{"CBAUD"};
  $cflag |= $constants{"BOTHER"};
  substr($to, $constants{"c_cflag_offset"}, $constants{"c_cflag_size"}) = pack "I", $cflag;
  
  # B: Modify c_ispeed
  if($direction & 1) {
    substr($to, $constants{"c_ispeed_offset"}, $constants{"c_ispeed_size"}) = pack "I", $baudrate;
  }
  
  # C: Modify c_ospeed
  if($direction & 2) {
    substr($to, $constants{"c_ospeed_offset"}, $constants{"c_ospeed_size"}) = pack "I", $baudrate;
  }
  
  # Fourth: Call TCSETS2
  ioctl($fh, $constants{"TCSETS2"}, $to) or return -1;
  
  return 0;
}

# open_serial - get an FD to a serial port, having done proper DTR and
# baudrate setting
sub open_serial {
  my ($self, $port, $speed) = @_;

  if(defined($self->{FD})) {
    # Close the existing one
    close($self->{FD});
  }

  # We open the port using SerialPort just to 
  # waggle the DTR to reset it
  # We probably do this ourselves later as well,
  # but that doesn't seem to work 100% reliably
  my $fake = Device::SerialPort->new($port);
  if($fake) {
    $fake->baudrate($speed);
    $fake->databits(8);
    $fake->parity(0);
    $fake->handshake('none');
    $fake->pulse_dtr_on(100);
    $fake = undef;
  }

  # We now open the port again, but do so using our
  # own IO::Handle object, so that we can use select()
  # on it (which you can't do with the SerialPort object)
  my $new = IO::File->new();
  unless(open($new, "+<:bytes", $port)) {
    #print "Failed to open '$port': $!\n";
    return 0;
  }
  # Try to set the baud rate...
  set_baudrate($new, 3, $speed);

  # On rasbian, we have to turn off echos
  # (We can't use SerialPort to do this)
  system("/bin/stty -F \"$port\" -echo -echoe -echonl");

  # Remember the object...
  $self->{FD} = $new;
  $self->{FILENAME} = $port;
  $self->{SPEED} = $speed;

  $new->autoflush(1);
  $new->blocking(0);

  $self->{READERS}->add_fd($self->{FD},$self);
  $self->{READ_BUF} = '';

  return 1;
}

sub close_serial {
  my ($self) = @_;
  if(defined($self->{FD})) {
    $self->{READERS}->remove_fd($self->{FD});
    $self->{WRITERS}->remove_fd($self->{FD});
    $self->clear_buffers();
    close($self->{FD});
    $self->{FD} = undef;
    $self->{FILENAME} = undef;
    $self->{SPEED} = 0;
    return 1;
  }
  return 0;
}

# Put something in our outgoing buffer for later sending
sub write_buffer {
  my ($self, $thing) = @_;
  my $ret = 0;
  if(defined($thing)) {
    push @{$self->{WRITE_BUF}}, $thing;
    if(defined($self->{FD})) {
      $self->{WRITERS}->add_fd($self->{FD}, $self);
      $ret = 1;
    }
  }
  return $ret;
}

# actually send something down the serial port. This uses
# system buffered IO, so hopefully sending a string won't
# block here.
sub write_fd {
  my ($self) = @_;
  my $thing = pop(@{$self->{WRITE_BUF}});
  if($thing) {
    $self->print(5, "Sending >$thing< out...");
    $self->{FD}->write("$thing\n");
  } elsif($#{$self->{WRITE_BUF}} < 0) {
    # Nothing to send, so take ourselves out
    $self->{WRITERS}->remove_fd($self->{FD});
  }
}

# read_fd - read something from our serial port.
# This reads through the system buffered IO, so hopefully won't
# just read one character at a time(!). Either way, we put the
# characters just read on the end of our internal buffer for
# later reading.
sub read_fd {
  my ($self) = @_;

  return if(!defined($self->{FD}));

  my $buffer = '';

  my $i = $self->{FD}->sysread($buffer, 4096);
  $self->print(5, "Read $i bytes from FD: $buffer");
  my $fd = $self->{FD};
  if(!defined($i)) {
    # Looks like EOF or something
    $self->print(10, "Error reading descriptor: $!");
    return;
  } elsif($i > 0) {
    $self->{READ_BUF} .= $buffer;
    # See if the buffer is sufficiently full now
    if(length($self->{READ_BUF}) >= 2048) {
      # Buffer sufficiently big - stop trying to read any more
      $self->{READERS}->remove_fd($self->{FD});
      $self->{READ_BUFFER_FULL} = 1;
    }
  } else {
    # Read zero bytes - means the port has disappeared/closed
    # on us.
    $self->print(10, "Port has closed, so disconnecting from it");
    $self->close_serial();
  }
}

# Grab something from our internal buffer. Needs read_fd to fill
# the buffer from time to time.
sub read_buffer {
  my ($self) = @_;

  # We need to 'pop' a command off the read buffer. It's a string
  # with some new lines in it, so pull something off it and return
  # it. Since this is a control port, we're not expecting too
  # many schenanigans here - so don't need to be super-defensive
  # about the lines we're reading and whatnot. Just skip blank lines
  # and remove comments.
  while(length($self->{READ_BUF}) > 0) {
    if($self->{READ_BUF} =~ s/^(.*)[\r\n]+//) {
      my $string = $1;
      $self->print(5, "popped >$string< from buffer");
      return $string;
    } else {
      # Buffer not sufficiently full
      last;
    }
  }
  # We've either balied out of the loop, or have run out of
  # buffer.
  # Make sure we're looking out for more to read if the buffer is low
  if($self->{READ_BUFFER_FULL} && defined($self->{FD}) && length($self->{READ_BUF}) < 2048) {
    $self->{READERS}->add_fd($self->{FD}, $self);
  }
  return undef;
}

# Return some internal state to the caller
sub status {
  my ($self) = @_;
  return {
    'port' => $self->{FILENAME},
    'speed' => $self->{SPEED},
    'connected' => defined($self->{FD}) ? 1 : 0,
  };
}  

1;
# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
