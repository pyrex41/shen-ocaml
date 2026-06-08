.PHONY: all shengen build test shen-check run clean

NIX_CMD = nix develop --command bash -c

all: shengen build test shen-check

# Gate 1: regenerate guard types from specs
shengen:
	./bin/shengen-codegen.sh

# Gate 2: build
build:
	$(NIX_CMD) 'dune build'

# Gate 3: test
test:
	$(NIX_CMD) 'dune test'

# Gate 4: verify specs with Shen tc+
shen-check:
	./bin/shen-check.sh

# Run the Ralph loop
run:
	./bin/ralph.sh

clean:
	$(NIX_CMD) 'dune clean'
