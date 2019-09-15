#!/bin/bash
# Talk with UEFI running in QEMU through named pipes
# Author: Artem Nefedov

usage()
{
	echo >&2 "
	Execute arbitrary command via named pipes 'serial.in' / 'serial.out'.
	QEMU must be running with '-serial pipe:serial' option.
	Exit code is 0 if command succeeds, or 1 otherwise.

	Usage:

	${0##*/} [options] COMMAND LIST
	${0##*/} [options] -w|-r|-s

	If multiple commands are specified, only last exit code is checked.

	Available options:

	-c    - print exit code (value of %LastError%)
	-e    - send 'Escape' to skip startup.nsh (requires '-w')
	-h    - show this help and exit
	-i    - ignore the value of %LastError% (always exit with 0)
	-p    - print output returned by the command without color codes
	-r    - send 'reset' command
	-s    - send 'reset -s' (shutdown) command
	-t ## - run with timeout
	-w    - wait for boot and skip 5-second prompt

	Environment variables:

	TIMEOUT_MULTIPLIER - if specified, all timeout times are multiplied.
	"
	exit 1
}

trap 'echo >&2 "$0: Error at $LINENO: $BASH_COMMAND"' ERR
set -E
set -e

unset print_exit_code ignore_error do_print do_reset timeout wait_boot
boot_keys=$'\r\n'
opts=()

while getopts cehiprst:w opt; do
	opts+=( -"$opt" ${OPTARG+"$OPTARG"} )
	case "$opt" in
		c)
			print_exit_code=1
			;;
		e)
			boot_keys=$'\e'
			;;
		h)
			usage
			;;
		i)
			ignore_error=1
			;;
		p)
			do_print=1
			;;
		r)
			do_reset='reset'
			;;
		s)
			do_reset='reset -s'
			;;
		t)
			opts=( "${opts[@]:0:$(( ${#opts[@]} - 2 ))}" )
			timeout=$OPTARG
			;;
		w)
			wait_boot=1
			;;
		*)
			exit 1
			;;
	esac
done

shift $(( OPTIND - 1 ))

if [ -n "$timeout" ]; then
	if [ -n "$TIMEOUT_MULTIPLIER" ]; then
		timeout=$(( timeout * TIMEOUT_MULTIPLIER ))
	fi
	# --foreground is fine because we spawn no child processes
	timeout --foreground -s 9 "$timeout" "$0" "${opts[@]}" "$@"
	exit 0
fi

while [ ! -e serial.out ]; do
	sleep 0.1
done

unset first_match

if [ -n "$wait_boot" ]; then
	test -z "$1" || usage
	expect='or any other key to continue.'
else
	if [ -n "$do_reset" ]; then
		test -z "$1" || usage
		# check that VM is responsive before doing reset
		set -- "echo Calling reset"
	fi

	test -n "$1" || usage
	expect='LastError='
	first_match=1

	cmdline=''
	for cmd in "$@" 'echo "Last"Error=%lasterror%'; do
		cmdline+="$cmd"$'\r\n'
	done

	# clear pipe
	while IFS='' read -r -n 1 -d '' -t 0.2 c; do
		:
	done < serial.out

	echo -n "$cmdline" > serial.in
fi

print_out()
{
	# remove color codes and other stuff
	print_str=$(printf %s "${print_str//$'\r'/}" | \
		sed -r 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGKH]//g')

	# if only 1 command is called, remove command itself
	# ('*' is to avoid race condition with other serial output)
	print_str=${print_str#*"$1"$'\n'}

	if [ $# -gt 1 ]; then
		# otherwise, prefix 1st command with prompt string
		# (because other commands also have them)
		print_str="Shell> $1"$'\n'"$print_str"
	fi

	printf %s "${print_str%Shell> *}"
}

size=${#expect}
out=''
exit_code=''
print_str=''

while :; do
	test -e serial.out
	while IFS='' read -r -n 1 -d '' c; do
		out+=$c

		if [ ${#out} -gt $size ]; then
			out=${out:1}
		fi

		if [ -z "$wait_boot" ]; then
			if [ -z "$first_match" ]; then
				exit_code+=$c
			elif [ -n "$do_print" ]; then
				print_str+=$c
			fi
		fi

		if [ "$out" = "$expect" ]; then
			if [ -n "$first_match" ]; then
				unset first_match
				expect=$'\r'
				size=1
				out=''

				if [ -n "$do_print" ]; then
					print_out "$@"
				fi
			else
				exit_code=${exit_code%"$expect"}
				break 2
			fi
		fi
	done < serial.out
done

if [ -n "$print_exit_code" ] && [ -n "$exit_code" ]; then
	echo "$exit_code"
fi

ok_exit_code='^0x0+$'

if [ -n "$do_reset" ]; then
	echo -n "$do_reset"$'\r\n' > serial.in
	if [ "$do_reset" = 'reset -s' ]; then
		# confirm that there's no output anymore
		while IFS='' read -r -n 1 -d '' -t 0.2 c; do
			:
		done < serial.out
	fi
elif [ -n "$wait_boot" ]; then
	echo -n "$boot_keys" > serial.in
elif [ -z "$ignore_error" ] && [[ ! "$exit_code" =~ $ok_exit_code ]]; then
	exit 1
fi

exit 0

