package ByteTrain::Selecter;

# The Bytetrain - Gcode sender for 3D Printers and other gcode talkers
# (C) Ralph Bolton (github@coofercat.com), GNU Public License v2
# Written July 2014.

# Selecter is essentially a bit of a wrapper around IO::Select. It
# keeps track of the object that added an FD to the 'watch list',
# so that when select() gives us an FD, we can find out which
# object it belongs to.

use Exporter;
use vars qw($VERSION @ISA);

$VERSION     = 1.0;
@ISA         = qw(Exporter);

use strict;
use warnings;

use IO::Select;
use ByteTrain::Stacktrace;

sub new {
  my ($class) =@_;
  
  my $self = {};

  bless $self, $class;

  $self->{SELECT} = IO::Select->new();
  $self->{FDS_TO_OBJS} = {};

  return $self;
}

# Add an FD to the select "watch list"
sub add_fd {
  my ($self, $fd, $obj) = @_;

  my $key = fileno($fd);
  ByteTrain::Stacktrace::print() if(!defined($key));
  $self->{SELECT}->add($fd);
  $self->{FDS_TO_OBJS}->{$key} = $obj;
}

# Remove an FD from the watch list
sub remove_fd {
  my ($self, $fd) = @_;

  my $key = fileno($fd);
  ByteTrain::Stacktrace::print() if(!defined($key));
  $self->{SELECT}->remove($fd);
  delete($self->{FDS_TO_OBJS}->{$key});
}

# Return our IO::Select() object, which essentially
# means "return the watch list"
sub select {
  my ($self) = @_;

  return $self->{SELECT};
}

# Return all FDs on the watch list
sub fds {
  my ($self) = @_;

  return keys %{$self->{FDS_TO_OBJS}};
}

# Figure out which object an FD belongs to.
sub fd_to_obj {
  my ($self, $fd) = @_;

  my $key = fileno($fd);
  ByteTrain::Stacktrace::print() if(!defined($key));
  return $self->{FDS_TO_OBJS}->{$key};
}

1;
# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
