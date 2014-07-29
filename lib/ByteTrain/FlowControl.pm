package ByteTrain::FlowControl;

# The Bytetrain - Gcode sender for 3D Printers and other gcode talkers
# (C) Ralph Bolton (github@coofercat.com), GNU Public License v2
# Written July 2014.

# This module attempts to control the flow of Gcode to the printer.
# It does this by counting out the Gcode sent to the printer and
# counting back in the acknowledgements received.
#
# As a side effect, it keeps a number of counters which are possibly
# useful status information for consumers of the Bytetrain's services.

use Exporter;
use vars qw($VERSION @ISA);

$VERSION     = 1.0;
@ISA         = qw(Exporter);

use strict;
use warnings;

use constant INFLIGHT_GCODE => 1;

sub new {
  my ($class) =@_;
  
  my $self = {};

  bless $self, $class;

  $self->{VERBOSITY} = 1;

  $self->reset();

  return $self;
}

sub print {
  my ($self, $verbosity, $thing) = @_;

  if($verbosity >= $self->{VERBOSITY}) {
    print "FlowControl: $thing\n";
  }
}


sub reset {
  my ($self) = @_;

  $self->{OK} = 0;              # A count of how many "ok" lines were received
  $self->{ACK} = 0;             # Lines acknowledged (ok or other)
  $self->{FLOW_ERROR} = 0;      # Lines complaining about not being N+1
  $self->{CHECKSUM_ERROR} = 0;  # Lines causing a checksum error
  $self->{GCODE_SENT} = 0;
  $self->{DIRECT_SENT} = 0;
  $self->{PAUSED} = 0;          # Start paused so the caller doesn't try to print
                                # when there's no gcode open yet
}

# Pause - just wait wherever we are
sub pause {
  my ($self) = @_;

  $self->{PAUSED} = 1;
}

# Resume from pause
sub resume {
  my ($self) = @_;

  $self->{PAUSED} = 0;
}

# OK ack received
sub ok {
  my ($self) = @_;

  $self->{OK}++;
}

# Any ack received
sub ack {
  my ($self) = @_;

  $self->{ACK}++;
}

# Some sort of flow error (wrong line number, etc) received
sub flow_error {
  my ($self) = @_;
  $self->{FLOW_ERROR}++;
}

# Checksum error (ie serial transfer problem)
sub checksum_error {
  my ($self) = @_;
  $self->{CHECKSUM_ERROR}++;
}

# We're clear to send a line of gcode to the printer
sub okay_to_send {
  my ($self) = @_;

  return 0 if($self->{PAUSED});

  if(($self->{GCODE_SENT} + $self->{DIRECT_SENT}) < ($self->{ACK} + INFLIGHT_GCODE)) {
    return 1;
  }
  return 0;
}

# How much gcode was sent directly (and not as part of a file)
sub direct_gcode {
  my ($self) = @_;

  $self->{DIRECT_SENT}++;
}

# How much gcode has been sent to the printer since the last reset?
sub sent_gcode {
  my ($self) = @_;
  $self->{GCODE_SENT}++;
}

# Return some internal state to the caller
sub status {
  my ($self) = @_;

  return {
    'paused' => $self->{PAUSED},
    'gcode_sent' => $self->{GCODE_SENT},
    'direct_sent' => $self->{DIRECT_SENT},
    'ok' => $self->{OK},
    'ack' => $self->{ACK},
    'flow_error' => $self->{FLOW_ERROR},
    'checksum_error' => $self->{CHECKSUM_ERROR},
    'ots' => $self->okay_to_send(),
  };
}

1;
# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
