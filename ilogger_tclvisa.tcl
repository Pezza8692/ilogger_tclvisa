#!/opt/ActiveTcl-8.6/bin/tclsh
# Hey Emacs, use -*- Tcl -*- mode

# ---------------------- Command line parsing -------------------------
package require cmdline
# load tclvisa package into Tcl shell
package require tclvisa

set usage "usage: ilogger \[options]\n\n"
append usage "While the DM3058 can sample at 123 readings per second, it can only update\n"
append usage "its remote interface at 50 readings per second.\n"

set options {
    {p.arg none "Name of the instrument (DM3058E)"}
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

# Looking fr all the VISA instruments connected to the PC via USB
if { [catch { set rm [visa::open-default-rm] } rc] } {
  puts stderr "Error opening default resource manager\n$rc"
  exit
}

set visaAddr [visa::find $rm "USB0?*INSTR"]

if { [catch { set vi [visa::open $rm $visaAddr] } rc] } {
  puts "Error opening instrument `$visaAddr`\n$rc"
  # `rm` handle is closed automatically by Tcl
  exit
}


proc port_init {vi} {
    # Return a channel to the instrument, or exit if there's a problem
    #
    # Arguments:
    #   portnode -- The filesystem node specified as the -p argument
    try {
    puts $vi "*IDN?"
    set data [gets $vi]
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
    return $vi
}

proc rate_set {vi} {
    # Return the refresh rate based on the measurement rate setting
    #
    # Arguments:
    #   vi -- Communication channel
    global params
    if { [string equal $params(r) "slow"] } {
    puts $vi ":rate:current:dc s"
    set rate 2.5
    } elseif { [string equal $params(r) "medium"] } {
    puts $vi ":rate:current:dc m"
    set rate 20
    } else {
    puts $vi ":rate:current:dc f"
    set rate 50
    }
}

proc range_set {vi} {
    # Return the full-scale range in mA
    #
    # Arguments:
    #   vi -- Communications channel
    global params
    if { [string equal $params(f) "0.2"] } {
    puts $vi ":measure:current:dc 0"
    set range 0.2
    } elseif { [string equal $params(f) "2"] } {
    puts $vi ":measure:current:dc 1"
    set range 2
    } elseif { [string equal $params(f) "20"] } {
    puts $vi ":measure:current:dc 2"
    set range 20
    }  elseif { [string equal $params(f) "200"] } {
    puts $vi ":measure:current:dc 3"
    set range 200
    }  elseif { [string equal $params(f) "2000"] } {
    puts $vi ":measure:current:dc 4"
    set range 2000
    } else {
    puts $vi ":measure:current:dc 5"
    set range 10000
    }
    return $range
}

proc measurement_read {vi} {
    # Return the most recent measurement
    #
    # Arguments:
    #   vi -- Communications channel
    puts $vi ":measure:current:dc?"
    set data [gets $vi]
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


proc measurement_schedule {vi rate millis_start} {
    # Returns a measurement at the requested rate
    #
    # Arguments:
    #   vi -- Communications channel
    #   rate -- Rate of measurements in Hz
    #   millis_start -- Milliseconds since epoch when script was called
    set data [measurement_read $vi]
    set period_ms [expr round( 1.0/$rate * 1000)]
    after $period_ms [list measurement_schedule $vi $rate $millis_start]
    measurement_report $millis_start $data
}


# Set up the channel
set vi [port_init $vi]

# Configure current measurement
puts $vi ":function:current:dc"

# Configure measurement rate
set measurement_rate [rate_set $vi]

# Configure measurement range
set measurement_range [range_set $vi]

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
measurement_schedule $vi $measurement_rate $millis_start

# Start the event loop
vwait forever