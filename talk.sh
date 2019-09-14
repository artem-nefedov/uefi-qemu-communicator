#!/bin/bash
# Talk with UEFI running in QEMU through named pipes
# Author: Artem Nefedov

usage()
{
	echo >&2 "
	Usage:

	${0##*/} [options] COMMAND LIST
	${0##*/} [options] -w|-r|-s

	If multiple commands are specified, only last exit code is checked.

	Available options:

	-e    - send 'Escape' to skip startup.nsh (requres '-w')
	-h    - show this help and exit
	-i    - ignore the value of %LastError%
	-r    - send 'reset' command
	-s    - send 'reset -s' (shutdown) command
	-t ## - run with timeout
	-w    - wait for boot and skip 5-second prompt
	"
	exit 1
}

trap 'echo >&2 "$0: Error at $LINENO: $BASH_COMMAND"' ERR
set -E
set -e

unset ignore_error do_reset timeout wait_boot
boot_keys=$'\r\n'
opts=()

while getopts ehirst:w opt; do
	opts+=( -"$opt" ${OPTARG+"$OPTARG"} )
	case "$opt" in
		e)
			boot_keys=$'\e'
			;;
		h)
			usage
			;;
		i)
			ignore_error=1
			;;
		r)
			do_reset='reset'
			;;
		s)
			do_reset='reset -s'
			;;
		t)
			opts=( "${opts[@]:2}" )
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

size=${#expect}
out=''
final_out=''

while :; do
	test -e serial.out
	while IFS='' read -r -n 1 -d '' c; do
		out+=$c

		if [ ${#out} -gt $size ]; then
			out=${out:1}
		fi

		if [ -z "$first_match" ]; then
			final_out+=$out
		fi

		if [ "$out" = "$expect" ]; then
			if [ -n "$first_match" ]; then
				unset first_match
				expect=$'\r'
				size=1
				out=''
			else
				final_out=${final_out%$'\r'}
				break 2
			fi
		fi
	done < serial.out
done

if [ -n "$do_reset" ]; then
	echo -n "$do_reset"$'\r\n' > serial.in
elif [ -n "$wait_boot" ]; then
	echo -n "$boot_keys" > serial.in
elif [ -z "$ignore_error" ] && [ "$final_out" != 0x0 ]; then
	exit 1
fi

exit 0
