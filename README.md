bytetrain
=========

A gcode sender designed for use in other applications that (possibly) run on resource-constrained hardware.

The Bytetrain is a compact, event based gcode sender that has machine-readable
input and output, low memory and CPU footprint, and a low level of
intelligence (it's really restricted to just what it needs to be able to
send gcode down a serial port). It provides no GUI or other application
intelligence so that other applications can perform these functions in
whatever manner they see fit.

The purpose of this project is to build a fast, reliable gcode sender that
can be embedded into other applications and suites. Whilst trying to build
other systems around gcode and the machines that speak it, system builders
can now use the Bytetrain rather than having to code up their own gcode-
talking subsystems.

When run, the Bytetrain opens up two Unix-level FIFO sockets, one for input
and the other for output. These form the means of controlling the Bytetrain
process from other applications. The input has a line-by-line command
model, with commands easily constructed by humans and programs alike. The
output channel is similarly easily interpreted by humans and programs,
again using a simple line-prefix output.

The Bytetrain comes with three main 'binaries'. The first is the daemon
itself. There are two others for manual and simple interactions with the
daemon. The 'hear.pl' script connects to the Bytetrain's output socket
and simply echos whatever it receives from it to STDOUT. Conversely,
the 'say.pl' script sends any command line arguments it is called with
down the Bytetrain's input socket. See USING for more details.

Since the Bytetrain is small and lightweight, it can be run with higher
Unix scheduler priority than normal processes. This ensures it receives
system resources as quickly as possible when it needs them, further
ensuring that it is able to completely fill the serial port to the
gcode-talking machine it is connected to. Flow control algorithms ensure
that gcode is sent when appropriate, without over-filling buffers
or sending so much gcode that the host and machine are never too far
apart. Serial transmission correctness, and gcode execution ordering
are enforced by sending gcode with line numbers and checksums.
