package ByteTrain;

# The Bytetrain - Gcode sender for 3D Printers and other gcode talkers
# (C) Ralph Bolton (github@coofercat.com), GNU Public License v2
# Written July 2014.

use Exporter;
use vars qw($VERSION @ISA);

$VERSION     = 1.0;
@ISA         = qw(Exporter);

use strict;
use warnings;

use IO::Select;

use ByteTrain::Serial;
use ByteTrain::GcodeFile;
use ByteTrain::Control;
use ByteTrain::Selecter;
use ByteTrain::FlowControl;

sub new {
  my ($class, $res_class) =@_;
  
  my $self = {};

  bless $self, $class;

  $self->{VERBOSITY} = 10;

  $self->{READERS} = ByteTrain::Selecter->new();
  $self->{WRITERS} = ByteTrain::Selecter->new();

  $self->{DEBUG_GCODE_FLOW} = 0;

  $self->{PRINTING} = 0;

  return $self;
}

# This unoriginally named method writes to STDOUT
# not to be confused with sending something to the printer ;-)
sub print {
  my ($self, $verbosity, $thing) = @_;

  if($verbosity >= $self->{VERBOSITY}) {
    print "ByteTrain: $thing\n";
  }
}

sub print_some_gcode {
  my ($self) = @_;
  # Now see if we're clear to print
  if($self->{FLOW}->okay_to_send()) {
    # Pull something from gcode, and give it to serial to print
    my $line = $self->{GCODE}->gcode();
    if(defined($line)) {
      if($self->{DEBUG_GCODE_FLOW}) {
        $self->{CONTROL}->write_buffer("TX: $line");
      }
      $self->{SERIAL}->write_buffer($line);
      $self->{FLOW}->sent_gcode();
    } else {
      # Nothing back from gcode - this could be EOF
      # or a buffer underrun
      my $status = $self->{GCODE}->status();
      # Don't worry about anything if we're not actually printing something
      if($self->{PRINTING}) {
        # If open and !okay, then we have a buffer underrun
        # otherwise, if !open and !okay, then we're EOF
        # If we're okay, then we just got undef for some
        # weird reason (code bug, probably)
        if($status->{'okay'}) {
          # Code bug
          $self->print(10,"Got nothing back from gcode object, but it says it is okay and has items to give us - code bug?");
        } else {
          if($status->{'open'}) {
            # File still open, but nothing in the buffer, so underrun
            my @out = ();
            foreach my $item (reverse sort keys %$status) {
              push @out, "$item=" . $status->{$item};
            }
            $self->{CONTROL}->write_buffer("Gcode Buffer underrun! " . join(' ', @out));
            $self->print(10, "Buffer underrun! " . join(' ', @out));
            return 0;
          } else {
            # Not okay, and file is closed - we're done
            $self->{FLOW}->pause();
            $self->{CONTROL}->write_buffer("PRINT: finished");
            $self->{SERIAL}->write_buffer("RESET");
            $self->{PRINTING} = 0;
          }
        }
      } # if gcode_open
    }
    return 1;
  } else {
    return 0;
  }
}

# This method just makes a nice string from a hash. It's used to send status
# information down the control port
sub hash_to_string {
  my ($self, $hash_ref, @quote) = @_;

  my @out = ();
  foreach my $key (sort keys %$hash_ref) {
    my $value = defined($hash_ref->{$key}) ? $hash_ref->{$key} : '(undef)';
    $value = grep(/$key/, @quote) ? "\"$value\"" : $value;
    push @out, "$key=$value";
  }
  return join(' ', @out);
}

sub abort_print {
  my ($self) = @_;

  $self->{FLOW}->pause();
  $self->{GCODE}->close_gcode();
  $self->{GCODE}->reset();
  $self->{SERIAL}->clear_buffers();
  $self->{FLOW}->reset();
  $self->{CONTROL}->write_buffer("ABORT: ok (print abandoned)");
  $self->{PRINTING} = 0;
}

# process something that's come from the control port. Essentially,
# this is a matter of reading a line of input and scheduling we
# do something
sub process_control {
  my ($self) = @_;
  while(my $buf = $self->{CONTROL}->read_buffer()) {
    $self->print(5, "Control read buffer contains >$buf<");

    if($buf =~ /^PRINT\s+(.+)/) {
      my $ret = $self->{GCODE}->open_gcode($1);
      if($ret) {
        $self->{FLOW}->reset();
        $self->{CONTROL}->write_buffer("PRINT: ok (printing $1)");
        #$self->{FLOW}->resume();
        $self->{PRINTING} = 1;
      } else {
        $self->{CONTROL}->write_buffer("PRINT: Failed to open $1: $!");
      }

    } elsif($buf =~ /^SERIAL\s+(\S+)(\s+(\S+))?/) {
      my $port = $1;
      my $speed = $3;
      $speed = ($speed && $speed =~ /^\d+$/) ? $speed : 250000;
      if($port eq 'disconnect') {
        if($self->{SERIAL}->close_serial()) {
          $self->{CONTROL}->write_buffer("SERIAL: ok (disconnected)");
          $self->abort_print() if($self->{PRINTING});
        } else {
          $self->{CONTROL}->write_buffer("SERIAL: Failed to disconnect: $!");
        }
      } else {
        if($self->{SERIAL}->open_serial($port, $speed)) {
          $self->{CONTROL}->write_buffer("SERIAL: ok (opened $port at $speed baud)");
        } else {
          $self->{CONTROL}->write_buffer("SERIAL: Failed to open $1: $!");
        }
      }

    } elsif($buf =~ /^GCODE\s+(.+)/) {
      $self->{SERIAL}->write_buffer($1);
      # Also tell the flow module about the injection so
      # that it counts the number of acks and commands correctly
      $self->{FLOW}->direct_gcode();

    } elsif($buf eq 'PAUSE') {
      $self->{FLOW}->pause();
      $self->{CONTROL}->write_buffer("PAUSE: ok (paused)");

    } elsif($buf eq 'RESUME') {
      $self->{FLOW}->resume();
      $self->{CONTROL}->write_buffer("RESUME: ok (resumed)");

    } elsif($buf eq 'DEBUG') {
      $self->{DEBUG_GCODE_FLOW} = 1;
      $self->{SERIAL}->{DEBUG_GCODE_FLOW} = 1;
      $self->{CONTROL}->write_buffer("DEBUG: ok");

    } elsif($buf eq 'NODEBUG') {
      $self->{DEBUG_GCODE_FLOW} = 0;
      $self->{SERIAL}->{DEBUG_GCODE_FLOW} = 0;
      $self->{CONTROL}->write_buffer("NODEBUG: ok");

    } elsif($buf eq 'ABORT') {
      $self->abort_print();

    } elsif($buf eq 'STATUS') {
      my @statuses = ($self->{GCODE}->status(), $self->{FLOW}->status(), $self->{SERIAL}->status());
      # Should we check for illegal statuses here? Eg. printing = 1 but connected = 0?
      # If so, we could clean up and then refetch status before returning it
      my @out = ('printing=' . $self->{PRINTING});
      foreach my $item (@statuses) {
        push @out, $self->hash_to_string($item, 'filename');
      }
      $self->{CONTROL}->write_buffer("STATUS: " . join(' ', @out));
    }
  }
}

# Process something from the serial port. This could be anything
# the printer throws at us. In most cases, it's just an ACK, but
# it could be flow errors requiring we alter our output.
sub process_serial {
  my ($self) = @_;

  while(my $buf = $self->{SERIAL}->read_buffer()) {
    my $echo_it_to_control = 1;
    if($buf =~ /^ok\s*(.*)$/) {
      $self->{FLOW}->ok();
      if($1 =~ /^\s*$/) {
        $echo_it_to_control = $self->{DEBUG_GCODE_FLOW};
      }
      $self->{FLOW}->ack();
    } elsif($buf =~ /Error/) {
      if($buf =~ /Error:checksum mismatch, Last Line:\s+(\d+)\s*.*$/) {
        # Count these errors
        $self->{FLOW}->checksum_error();

        # Now try to rewind to the right place
        my $last_good_n = $1;
        my $rewind_to = $last_good_n + 1;
        if($self->{GCODE}->rewind($rewind_to)) {
          $self->{CONTROL}->write_buffer("GCODE: Checksum mismatch - rewinding to line N$rewind_to");
        } else {
          # This is really a catastrophic failure and should end printing this file
          $self->{GCODE}->close_gcode();
          $self->{GCODE}->reset();
          $self->{FLOW}->reset();
          $self->{CONTROL}->write_buffer("GCODE: Could not rewind to line N$rewind_to - printing aborted");
        }
      } elsif($buf =~ /Error:Line Number is not Last Line Number+1, Last Line:\s+(\d+)\s*.*$/) {
        # Ordinarily, we can ignore these errors because we'll catch the cause
        # and so don't need to worry about these (plus, if we process these
        # and the cause, we'll double-process, which causes flow issues)
        # So, we mostly just tally up how many of these we see - if it gets excessive
        # then we can bomb out or whatever
        $self->{FLOW}->error();
      }
      $self->{FLOW}->ack();
    }
    if($echo_it_to_control) {
      $self->{CONTROL}->write_buffer("RX: $buf");
    }
  }

  $self->print_some_gcode();
}


sub run {
  my ($self) = @_;

  # Create all the other objects we need to run.
  # We've got 'readers' and 'writers' already, which we hand
  # to the objects to use
  $self->{CONTROL} = ByteTrain::Control->new($self->{READERS}, $self->{WRITERS}) or die "Could not create ByteTrain::Control: $!";
  $self->{GCODE} = ByteTrain::GcodeFile->new($self->{READERS}) or die "Could not create ByteTrain::GCodeFile: $!";
  $self->{SERIAL} = ByteTrain::Serial->new($self->{READERS}, $self->{WRITERS}, $self->{GCODE}) or die "Could not create ByteTrain::Serial: $!";
  $self->{FLOW} = ByteTrain::FlowControl->new();

  my $select_timeout = 10;

  # This is the main event loop. We wait for something to happen on
  # any one of our read or write descriptors. The sub-modules will
  # tell us to watch the descriptiors that they want to have watched.
  # When something happens, we call them to tell them to process the
  # descriptor. 
  while(1) {
    $self->print(1, "Doing select with timeout=$select_timeout");
    my ($can_read, $can_write, undef) = IO::Select::select($self->{READERS}->select(), $self->{WRITERS}->select(), undef, $select_timeout);
    if($#{$can_read} >= 0) {
      foreach my $read_fd (@{$can_read}) {
        # From the FD, find out which object to call, then tell
        # it to process the descriptor. All modules have a "read_fd"
        # method. Once they've done that, we probably have to do some
        # work depending on what they've just received.
        my $obj = $self->{READERS}->fd_to_obj($read_fd);
        $obj->read_fd();
        if(ref($obj) eq 'ByteTrain::GcodeFile') {
          # Nothing here...?
        } elsif(ref($obj) eq 'ByteTrain::Serial') {
          $self->process_serial();
        } elsif(ref($obj) eq 'ByteTrain::Control') {
          $self->process_control();
        } else {
          $self->print(10, "Unsupported object from reader FD is $obj");
        }
      }
    }
    # If any watched descriptors are writable, then call the right object to
    # write something to it.
    if($#{$can_write} >= 0) {
      foreach my $write_fd (@{$can_write}) {
        my $fileno = fileno($write_fd);
        my $obj = $self->{WRITERS}->fd_to_obj($write_fd);
        $obj->write_fd();
      }
    }

    # We've now services any read/write tasks that needed doing. Now we need to
    # actually print some gcode (if we're supposed to be printing). 
    my $gcode_status = $self->{GCODE}->status();
    my $flow_status = $self->{FLOW}->status();
    if($gcode_status->{'gcode_read'} && $flow_status->{'paused'} == 0 && $flow_status->{'ack'} == 0) {
      $self->print_some_gcode();
    }
  }
}

1;
# This is for Vim users - please don't delete it
# vim: set filetype=perl expandtab tabstop=2 shiftwidth=2:
