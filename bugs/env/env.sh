# Source from the repository root after building (make; make -C tests machine uarch images):
#   source bugs/env/env.sh
# Sets the library/Lua paths of the in-tree build and the test data locations used by the bug tests.
eval "$(make -s env)"
export CARTESI_IMAGES_PATH=${CARTESI_IMAGES_PATH:-$(pwd)/tests/build/images}
export CARTESI_TESTS_PATH=${CARTESI_TESTS_PATH:-$(pwd)/tests/build/machine}
export CARTESI_TESTS_UARCH_PATH=${CARTESI_TESTS_UARCH_PATH:-$(pwd)/tests/build/uarch}
export CM_CLI=${CM_CLI:-$(pwd)/src/cartesi-machine.lua}
