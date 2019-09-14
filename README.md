# Talk with UEFI running in QEMU through named pipes

The script can run any arbitrary command and retrieve its exit code,
wait for boot and skip the 5-second prompt (and optionally skip startup.nsh),
or send reset/shutdown commands.

There are extra options, such as timeout for the command execution.

Script assumes you're created named pipes 'serial.in' / 'serial.out',
and running QEMU with '-serial pipe:serial' option.

Output for executed commands is NOT printed to terminal.
If you wish to capture output, simply specify additional '-serial' option.
E.g.:

```
mkfifo serial.in serial.out
qemu-system-i386 ... -serial file:out.log -serial pipe:serial &
tail -f out.log
```

Code written in pure BASH with no subprocesses spawned.
