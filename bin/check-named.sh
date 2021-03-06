#!/bin/bash
#
# This script runs under the ksh, POSIX, and bash shells.
#
shopt -qs extglob	# Uncomment this line if running under the bash shell.

# NOTE: This script does not function with the current versions of
#       BIND9 because that name server does not log a message when
#       it has finished acting on an event, i.e., there is nothing
#       analogous to a "Ready to answer queries" message.
#
program_name=${0##*/}
LOGDIR=/var/adm/syslog
SYSLOG="$LOGDIR/syslog.log"
TMPDIR=/tmp
NDC=/usr/sbin/ndc
DIGPATH=/usr/local/bin
COMMAND="'[re]start' or 'reload'"
SIGNAL="(starting.|reloading nameserver)"
USAGE="\
Usage: $program_name [-f log_file] [load|start|conf|any]\n\
       Checks the last status of an 'ndc [re]start|reload|reconfig' command\n\
       in the default or specified system log file.\n\n\
       -f     specifies alternate '$LOGDIR/log_file' to search\n\
       load   checks last '[re]start' or 'reload' [default]\n\
       start  checks last '[re]start' only\n\
       conf   checks last 'reconfig' only\n\
       any    checks last '[re]start', 'reload', or 'reconfig'\n"

while (($# > 0))
do
  #
  # Parse the command-line argument(s).
  #
  case $1 in
	      -f*)  # Alternate log file.
		    #
		    arg=${1#-f}
		    if [[ -n $arg ]]
		    then
		      SYSLOG="$LOGDIR/$arg"
		    else
		      if (($# > 1))
		      then
			SYSLOG="$LOGDIR/$2"
			if [[ -f $SYSLOG ]]
			then
			  shift
			else
			  printf "Error: file '%s' does not exist.\n\n" $SYSLOG\
				 >&2
			  exit 1
			fi
		      else
			printf "%s: Missing argument for '-f'\n" $program_name \
			       >&2
			IFS=""		# preserve contiguous whitespace
			printf "%b\n" "$USAGE" >&2
			exit 2
		      fi
		    fi;;
	?(re)load)  #
		    COMMAND="'[re]start' or 'reload'"
		    SIGNAL="(starting.|reloading nameserver)";;
       ?(re)start)  #
		    COMMAND="'[re]start'"
		    SIGNAL="starting.";;
   ?(re)conf?(ig))  #
		    COMMAND="'reconfig'"
		    SIGNAL="(reconfiguring nameserver)";;
	      any)  #
		    COMMAND="'[re]start', 'reload' or 'reconfig'"
		    SIGNAL="(starting.|re(load|configur)ing nameserver)";;
?(-)@(h?(elp)|\?))  #
		    IFS=""
		    printf "%b\n" "$USAGE"
		    exit 0;;
		*)  #
		    printf "%s: Invalid argument '%s'\n" $program_name $1 >&2
		    IFS=""
		    printf "%b\n" "$USAGE" >&2
		    exit 2;;
  esac
  shift
done

named_status=$($NDC status 2>&1)
if [[ $named_status = *"server is "@(up and running|initialising itself)* ]]
then
  #
  # Query for the version of BIND that is running.
  #
  BIND_version=$($DIGPATH/dig @localhost version.bind chaos txt | \
		 grep -i '^version.bind' | sed -e 's/[^\"]*//')
  printf "\nNameserver process is running BIND version %s.\n" "$BIND_version"
else
  printf "\nWARNING!  No name server process is currently running.\n"
fi
printf "The last logged status of ndc %s is:\n\n" "$COMMAND"

#
# If any zone file contained errors, they would be logged between the
# messages that 'named' is either "starting" or "reloading" and that
# it is "Ready to answer queries".
# The following section will attempt to extract the 'named' log entries
# between these two messages.
#
# Due to the peculiarities of the 'csplit(1)' command that will be
# called later, we must first use the 'fold(1)' command to break up any
# lines in the syslog file that are longer than 254 characters.
# 'csplit(1)' also misbehaves when dealing with data piped into its
# standard input.  That is why 'fold(1)' does not pipe its output
# directly into 'csplit(1)'.
#
fold -b -254 $SYSLOG > $TMPDIR/folded_log_$$
((start_line = $(grep -En " named\[[0-9]*\]: $SIGNAL" $TMPDIR/folded_log_$$ | \
		 tail -1 | sed -e 's/:.*//') - 1))
if ((start_line == -1))
then
  printf "No occurences found in '%s'\n\n" $SYSLOG
  rm $TMPDIR/folded_log_$$
  exit
fi

ready=false
until [[ $ready = true ]]
do
  csplit -s -f $TMPDIR/syslog_part $TMPDIR/folded_log_$$ "%.%+$start_line" \
	   '/Ready to answer queries./+1' 2> $TMPDIR/csplit_error_$$
  if [[ -s $TMPDIR/csplit_error_$$ ]]
  then
    #
    # Make sure that the error returned by 'csplit(1)'
    # is what we think it is.
    #
    csplit_error="$(< $TMPDIR/csplit_error_$$)"
    if [[ $csplit_error = "/Ready to answer queries./+1 - out of range" ]]
    then
      #
      # The name server is not yet ready to answer DNS queries.
      # Wait a bit while 'named' processes the new zone data.
      #
      sleep 5
      #
      # Fold a fresh copy of the syslog file.
      #
      fold -b -254 $SYSLOG > $TMPDIR/folded_log_$$
    else
      #
      # 'csplit(1)' returned an unexpected error.  Report the situation,
      # clean up our temporary files, and exit the script.
      #
      printf "ERROR: The 'csplit(1)' command returned the following message:\n"\
	     >&2
      printf "\n"
      cat $TMPDIR/csplit_error_$$ >&2
      printf "\nYou must inspect '%s' manually\n" $SYSLOG >&2
      printf "to make sure that 'named' encountered no errors with the\n" >&2
      printf "new zone files.\n\n" >&2
      rm $TMPDIR/folded_log_$$ $TMPDIR/csplit_error_$$
      exit 2
    fi
  else
    ready=true
    rm $TMPDIR/csplit_error_$$
  fi
done

grep ' named\[[0-9]*\]: ' $TMPDIR/syslog_part00 | grep -Ev \
  -e '(USAGE|[NX]STATS|listening on|Forwarding.*address|zone.*loaded)' \
  -e '(unrelated additional|suppressing duplicate|NOTIFY|query from)'
printf "\n"

rm $TMPDIR/folded_log_$$ $TMPDIR/syslog_part[0-9][0-9]

exit 0
