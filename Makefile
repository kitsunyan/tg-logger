.PHONY: all clean

all: tglogger

tglogger: *.nim
	nim c -o:$@ $<

clean:
	rm tglogger
