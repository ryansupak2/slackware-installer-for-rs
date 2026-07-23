# slock - minimal X11 screen locker (colors match wlock)

PREFIX    ?= /usr/local
BINDIR    ?= $(PREFIX)/bin

CC        ?= gcc
CFLAGS    += -std=c99 -Wall -Wextra -O2 -g
PKGS      := x11
CFLAGS    += $(shell pkg-config --cflags $(PKGS))
LDFLAGS   += $(shell pkg-config --libs $(PKGS)) -lpam

OBJ       := slock.o

all: slock

slock: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

install: slock
	install -Dm 755 slock $(DESTDIR)$(BINDIR)/slock

clean:
	rm -f slock $(OBJ)

.PHONY: all install clean
