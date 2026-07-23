# Makefile for voxd
# Build: make
# Install: make install (or run via steps/vox-sherpa.sh)

CC      = gcc
CFLAGS  = -O2 -Wall -Wextra -std=c11
LDFLAGS = -L/usr/local/lib -lsherpa-onnx-c-api -lasound -lX11 -lXtst -lpthread
INCLUDES = -I/usr/local/include -I.

TARGET  = voxd
SRCS    = voxd.c

.PHONY: all clean install

all: $(TARGET)

$(TARGET): $(SRCS) config.h
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(SRCS) $(LDFLAGS)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/$(TARGET)
	@echo "voxd installed to /usr/local/bin/voxd"
