VFLAGS = -O3 --x-assign fast --x-initial fast --noassert
SDL_CFLAGS = `sdl2-config --cflags`
SDL_LDFLAGS = `sdl2-config --libs`

sandy: sandy.exe

%.exe: %.mk
	make -j$$(nproc) -C ./obj_dir -f Vtop_$< OPT_FAST=-O2

%.mk: top_%.sv
	verilator ${VFLAGS} \
		-cc $< --exe main_$(basename $@).cpp -o $(basename $@) \
		-CFLAGS "${SDL_CFLAGS}" -LDFLAGS "${SDL_LDFLAGS}"

all: sandy

clean:
	rm -rf ./obj_dir

.PHONY: all clean
