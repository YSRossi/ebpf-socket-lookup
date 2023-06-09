# Steering connections to sockets with BPF socket lookup hook

Code and instructions for the lighting talk at [eBPF Summit 2020](https://ebpf.io/summit-2020/).

## Goal

Set up an echo service on 3 ports, but using just one TCP listening socket.

We will use BPF socket lookup to dispatch connection to the echo server.

## Download libbpf(v1.0+), bpftool, clang
## Start the echo server and test it

```
$ ncat -4kle /bin/cat 127.0.0.1 7777 &
[1] 11566
$ ss -4tlpn sport = 7777
State     Recv-Q   Send-Q    Local Address:Port   Peer Address:Port     Process         
LISTEN    0        10        127.0.0.1:7777       0.0.0.0:*             users:(("ncat",pid=11566,fd=3))
```

Open another terminal.
```
$ { echo test; sleep 0.1; } | nc -4 127.0.0.1 7777
test
```

## Find IP and check open ports

```
$ ip -4 addr show enp3s0
2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    inet 10.1.1.5/24 brd 10.1.1.255 scope global dynamic noprefixroute enp3s0
       valid_lft 18986sec preferred_lft 18986sec
```

IP is `10.1.1.5`.

```
$ nmap -sT -p 1-1000 10.1.1.5
Starting Nmap 7.80 ( https://nmap.org ) at 2023-06-10 00:16 CST
Nmap scan report for 10.1.1.5
Host is up (0.00012s latency).
Not shown: 999 closed ports
PORT    STATE SERVICE
111/tcp open  rpcbind

Nmap done: 1 IP address (1 host up) scanned in 13.08 seconds

```

Only port `111` is open.

## Load `echo_dispatch` BPF program

```
$ sudo bpftool prog load ./echo_dispatch.bpf.o /sys/fs/bpf/echo_dispatch_prog
$ sudo bpftool prog show pinned /sys/fs/bpf/echo_dispatch_prog
119: sk_lookup  name echo_dispatch  tag da043673afd29081  gpl
	loaded_at 2023-06-10T00:13:25+0800  uid 0
	xlated 272B  jited 159B  memlock 4096B  map_ids 4,5
	btf_id 110
```

## Pin BPF maps used by `echo_dispatch`

Mount a dedicated bpf file-system for our user `vagrant`:

```
$ mkdir bpffs
$ sudo mount -t bpf none bpffs
```

Pin `echo_ports` map

```
$ sudo bpftool map show name echo_ports
4: hash  name echo_ports  flags 0x0
	key 2B  value 1B  max_entries 1024  memlock 8192B
	btf_id 110

$ sudo bpftool map pin name echo_ports bpffs/echo_ports
```

Pin `echo_socket` map

```
$ sudo bpftool map show name echo_socket
5: sockmap  name echo_socket  flags 0x0
	key 4B  value 8B  max_entries 1  memlock 4096B
$ sudo bpftool map pin name echo_socket bpffs/echo_socket
```

## Insert Ncat socket into `echo_socket` map

Find socket owner PID and FD number:

```
vm $ ss -tlpne 'sport = 7777'
State    Recv-Q   Send-Q     Local Address:Port     Peer Address:Port  Process  
LISTEN   0        10             127.0.0.1:7777          0.0.0.0:*      users:(("ncat",pid=11566,fd=3)) uid:1000 ino:88481 sk:1 <->
```

Put the socket into `echo_socket` map using `socket-update` tool:

```
$ sudo ./sockmap-update 11566 3 bpffs/echo_socket
$ sudo bpftool map dump pinned bpffs/echo_socket
key: 00 00 00 00  value: 01 00 00 00 00 00 00 00
Found 1 element
```

Notice the value under key `0x00` is the socket cookie (`0x01`) we saw in `ss`
output (`sk:1`). Socket cookie is a unique identifier for a socket description
inside the kernel.

## Attach `echo_dispatch` to network namespace

Create a BPF link between the current network namespace and the loaded
`echo_dispatch` program with the `sk-lookup-attach` tool:

```
$ sudo ./sk-lookup-attach /sys/fs/bpf/echo_dispatch_prog /sys/fs/bpf/echo_dispatch_link
```

Examine the created BPF link:

```
$ sudo bpftool link show pinned /sys/fs/bpf/echo_dispatch_link
4: netns  prog 119  
	netns_ino 4026531840  attach_type sk_lookup 
$ ls -l /proc/self/ns/net
lrwxrwxrwx 1 ysrossi ysrossi 0  Jun 10 00:30 /proc/self/ns/net -> 'net:[4026531840]'
```

Notice the BPF link can be matched with the network namespace via its inode number.

## Enable echo service on ports 7, 77, 777

Populate `echo_ports` map with entries for open ports `7` (`0x7`), `77`
(`0x4d`), and `7777` (`0x0309`):

```
$ sudo bpftool map update pinned bpffs/echo_ports key 0x07 0x00 value 0x00
$ sudo bpftool map update pinned bpffs/echo_ports key 0x4d 0x00 value 0x00
$ sudo bpftool map update pinned bpffs/echo_ports key 0x09 0x03 value 0x00
$ sudo bpftool map dump pinned bpffs/echo_ports
[{
        "key": 7,
        "value": 0
    },{
        "key": 777,
        "value": 0
    },{
        "key": 77,
        "value": 0
    }
]

```

## Re-scan open ports on VM

```
$ nmap -sT -p 1-1000 10.1.1.5
Starting Nmap 7.80 ( https://nmap.org ) at 2023-06-10 00:33 CST
Nmap scan report for 10.1.1.5
Host is up (0.00016s latency).
Not shown: 996 closed ports
PORT    STATE SERVICE
7/tcp   open  echo
77/tcp  open  priv-rje
111/tcp open  rpcbind
777/tcp open  multiling-http

Nmap done: 1 IP address (1 host up) scanned in 13.08 seconds

```

Notice echo ports we have just configured are open.

## Test the echo service on all open ports

```
$ { echo one; sleep 0.1; } | nc -4 127.0.0.1 7
one
$ { echo two; sleep 0.1; } | nc -4 127.0.0.1 77
two
$ { echo three; sleep 0.1; } | nc -4 127.0.0.1 777
three
```
