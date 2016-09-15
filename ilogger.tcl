#!/opt/ActiveTcl-8.6/bin/tclsh
# Hey Emacs, use -*- Tcl -*- mode

# ---------------------- Command line parsing -------------------------
package require cmdline
set usage "usage: ilogger \[options]\n\n"
append usage "While the DM3058 can sample at 123 readings per second, it can only update\n"
append usage "its remote interface at 50 readings per second.\n"

set options {
    {p.arg none "Port (like /dev/usbtmc1)"}
    {r.arg slow "Readings per second: slow (2.5), medium (20), fast (123)"}
    {f.arg 200  "Full scale current (mA): 0.2, 2, 20, 200, 2000"}
    {o.arg none "Output file name"}
}

try {
    array set params [::cmdline::getoptions argv $options $usage]
} trap {CMDLINE USAGE} {msg o} {
    # Trap the usage signal, print the message, and exit the application.
    # Note: Other errors are not caught and passed through to higher levels!
    puts $msg
    exit 1
}

# Check for required port argument
if { [string equal $params(p) "none"] } {
    # The port parameter has not been specified
    puts ""
    set dialog "Port is required.  On linux, the DM3058 will show up as /dev/usbtmc1, \n"
    append dialog "and the argument would be /dev/usbtmc1"
    puts $dialog
    puts ""
    puts [cmdline::usage $options $usage]
    exit 1
} else {
    set portnode $params(p)
}

proc port_init {portnode} {
    # Return a channel to the instrument, or exit if there's a problem
    #
    # Arguments:
    #   portnode -- The filesystem node specified as the -p argument
    try {
	set portchan [open $portnode r+]
	chan puts $portchan ":*IDN?"
	set data [chan gets $portchan]
	if { [string first "DM3058E" $data] == -1 } {
	    puts "Connected to $portnode, but this is not a DM3058E"
	    exit 1
	} 
    } trap {POSIX ENOENT} {} {
	puts "Problem opening $portnode -- it doesn't exist"
	exit 1
    } trap {POSIX EACCES} {} {
	puts "Problem opening $portnode -- permission denied"
	exit 1
    }
    return $portchan
}

proc rate_set {portchan} {
    # Return the refresh rate based on the measurement rate setting
    #
    # Arguments:
    #   portchan -- Communication channel
    global params
    if { [string equal $params(r) "slow"] } {
	chan puts $portchan ":rate:current:dc s"
	set rate 2.5
    } elseif { [string equal $params(r) "medium"] } {
	chan puts $portchan ":rate:current:dc m"
	set rate 20
    } else {
	chan puts $portchan ":rate:current:dc f"
	set rate 50
    }
}

proc range_set {portchan} {
    # Return the full-scale range in mA
    #
    # Arguments:
    #   portchan -- Communications channel
    global params
    if { [string equal $params(f) "0.2"] } {
	chan puts $portchan ":measure:current:dc 0"
	set range 0.2
    } elseif { [string equal $params(f) "2"] } {
	chan puts $portchan ":measure:current:dc 1"
	set range 2
    } elseif { [string equal $params(f) "20"] } {
	chan puts $portchan ":measure:current:dc 2"
	set range 20
    }  elseif { [string equal $params(f) "200"] } {
	chan puts $portchan ":measure:current:dc 3"
	set range 200
    }  elseif { [string equal $params(f) "2000"] } {
	chan puts $portchan ":measure:current:dc 4"
	set range 2000
    } else {
	chan puts $portchan ":measure:current:dc 5"
	set range 10000
    }
    return $range
}

proc measurement_read {portchan} {
    # Return the most recent measurement
    #
    # Arguments:
    #   portchan -- Communications channel
    chan puts $portchan ":measure:current:dc?"
    set data [chan gets $portchan]
    return $data
}

proc measurement_report {millis_start value} {
    # Report measurement data
    #
    # Arguments:
    #   millis_start -- Milliseconds since epoch when script was called
    #   value -- Latest measurement value
    global params
    set millis_new [clock milliseconds]
    set millis_elapsed [expr $millis_new - $millis_start]
    set timestamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S"]
    puts "${timestamp},$millis_elapsed,${value}"
    if { [string equal $params(o) "none"] } {
	return
    } else {
	try {
	    set fp [open $params(o) a]
	    puts $fp "${timestamp},$millis_elapsed,${value}"
	    close $fp
	} trap {POSIX EACCES} {} {
	    puts "Problem opening $params(o) -- permission denied"
	}
    }
}


proc measurement_schedule {portchan rate millis_start} {
    # Returns a measurement at the requested rate
    #
    # Arguments:
    #   portchan -- Communications channel
    #   rate -- Rate of measurements in Hz
    #   millis_start -- Milliseconds since epoch when script was called
    set data [measurement_read $portchan]
    set period_ms [expr round( 1.0/$rate * 1000)]
    after $period_ms [list measurement_schedule $portchan $rate $millis_start]
    measurement_report $millis_start $data
}


# Set up the channel
set portchan [port_init $portnode]

# Configure current measurement
chan puts $portchan ":function:current:dc"

# Configure measurement rate
set measurement_rate [rate_set $portchan]

# Configure measurement range
set measurement_range [range_set $portchan]

# Initialize the datafile
if { ![string equal $params(o) "none"] } {
    if { [file exists $params(o)] } {
	puts "Cowardly refusing to overwrite $params(o)"
	exit 1
    }
    try {
	set fp [open $params(o) w]
	puts $fp "# Timestamp,millisecond counter (ms),current (A)"
	close $fp
    } trap {POSIX EACCES} {} {
	puts "Problem opening $params(o) -- permission denied"
	exit 1
    }
}

# Keep track of the start time.  We'll use this to make a millisecond
# counter for measurements.
set millis_start [clock milliseconds]

# Start the measurement schedule
measurement_schedule $portchan $measurement_rate $millis_start

# Start the event loop
vwait forever
