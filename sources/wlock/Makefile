# wlock - minimal Wayland screen locker (slock equivalent)

PREFIX    ?= /usr/local
BINDIR    ?= $(PREFIX)/bin

CC        ?= gcc
CFLAGS    += -std=c99 -Wall -Wextra -O2 -g
PKGS      := wayland-client xkbcommon
CFLAGS    += $(shell pkg-config --cflags $(PKGS))
LDFLAGS   += $(shell pkg-config --libs $(PKGS)) -lpam -lrt

OBJ       := wlock.o ext-session-lock-v1-protocol.o

all: wlock

wlock: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c ext-session-lock-v1-client.h ext-session-lock-v1-protocol.h
	$(CC) $(CFLAGS) -c -o $@ $<

install: wlock
	install -Dm 755 wlock $(DESTDIR)$(BINDIR)/wlock

clean:
	rm -f wlock $(OBJ)

.PHONY: all install clean
