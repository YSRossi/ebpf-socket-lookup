# SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)
# Copyright (c) 2020 Cloudflare

CC := clang
CFLAGS := -g -O2 -Wall -Wextra

PROGS := sockmap-update sk-lookup-attach echo_dispatch.bpf.o

.PHONY: all
all: $(PROGS)

sockmap-update: sockmap_update.c
	$(CC) $(CFLAGS) -o $@ $<

sk-lookup-attach: sk_lookup_attach.c
	$(CC) $(CFLAGS) -o $@ $<

echo_dispatch.bpf.o: echo_dispatch.bpf.c
	$(CC) $(CFLAGS) -target bpf -c -o $@ $<
	
.PHONY: clean
clean:
	rm -f $(PROGS)


